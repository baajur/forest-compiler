{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

module TypeChecker
  ( checkModule
  , checkModuleWithLineInformation
  , CompileError(..)
  , TypedModule(..)
  , TypedDeclaration(..)
  , TypedExpression(..)
  , TypedArgument(..)
  , typeOf
  , Type(..)
  , InvalidConstruct(..)
  , replaceGenerics
  , printType
  , TypeLambda(..)
  ) where

import Data.Either
import qualified Data.Foldable as F
import Data.List (find, intercalate)
import Data.List.NonEmpty (NonEmpty(..), nonEmpty, toList)
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe, maybeToList)
import Data.Semigroup
import Data.Sequence (replicateM)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Debug.Trace (trace)
import qualified Generics.Deriving as G
import Safe

import HaskellSyntax
import Language

showT :: Show a => a -> Text
showT = T.pack . show

data CompileError =
  CompileError InvalidConstruct
               (Maybe SourceRange)
               Text
  deriving (Eq, Show)

data InvalidConstruct
  = DeclarationError Declaration
  | ExpressionError Expression
  | DataTypeError ADT
  deriving (Eq, Show)

data CompileState = CompileState
  { errors :: [CompileError]
  , typeLambdas :: [TypeLambda]
  , types :: Map Ident Type
  , typedDeclarations :: [TypedDeclaration]
  , typeConstructors :: Map TypeLambda [TypedConstructor]
  } deriving (Eq, Show)

data TypedConstructor =
  TypedConstructor Ident
                   Int
                   [Type]
  deriving (Eq, Show)

data Type
  = Num
  | Float' -- TODO a better name, perhaps declare in another module? :(
  | Str
  | Lambda Type
           Type
  | Applied Type
            Type
  | Generic Ident
  | TL TypeLambda
  deriving (Eq, Show, Ord)

newtype TypeLambda =
  TypeLambda Ident
  deriving (Eq, Show, Ord)

newtype TypedModule =
  TypedModule [TypedDeclaration]
  deriving (Eq, Show)

data TypedDeclaration =
  TypedDeclaration Ident
                   [TypedArgument]
                   Type
                   TypedExpression
  deriving (Show, Eq, G.Generic)

data TypedExpression
  = Identifier Type
               Ident
  | Number Int
  | Float Float
  | Infix Type
          OperatorExpr
          TypedExpression
          TypedExpression
  | Apply Type
          TypedExpression
          TypedExpression
  | Case Type
         TypedExpression
         (NE.NonEmpty (TypedArgument, TypedExpression))
  | Let (NE.NonEmpty TypedDeclaration)
        TypedExpression
  | BetweenParens TypedExpression
  | String' Text
  | ADTConstruction Int
                    [TypedArgument]
  deriving (Show, Eq, G.Generic)

data TypedArgument
  = TAIdentifier Type
                 Ident
  | TANumberLiteral Int
  | TADeconstruction Ident
                     Int
                     [TypedArgument]
  deriving (Show, Eq, G.Generic)

expressionPosition :: LineInformation -> Expression -> Maybe SourceRange
expressionPosition (LineInformation expressionPositions _) expr =
  Map.lookup expr expressionPositions

topLevelPosition :: LineInformation -> TopLevel -> Maybe SourceRange
topLevelPosition (LineInformation _ topLevelPositions) topLevel =
  Map.lookup topLevel topLevelPositions

addDeclarations :: CompileState -> [TypedDeclaration] -> CompileState
addDeclarations state declarations =
  state {typedDeclarations = declarations ++ typedDeclarations state}

addError :: CompileState -> CompileError -> CompileState
addError state error = state {errors = error : errors state}

addTypeLambda :: CompileState -> TypeLambda -> CompileState
addTypeLambda state (TypeLambda name) =
  state
    { typeLambdas = TypeLambda name : typeLambdas state
    , types = Map.insert name (TL (TypeLambda name)) (types state)
    }

addTypeConstructors ::
     CompileState -> TypeLambda -> [TypedConstructor] -> CompileState
addTypeConstructors state typeLambda constructors =
  state
    { typeConstructors =
        Map.insertWith (++) typeLambda constructors (typeConstructors state)
    }

defaultTypes :: Map Ident Type
defaultTypes =
  Map.fromList [(ne "Int", Num), (ne "String", Str), (ne "Float", Float')]

checkModuleWithLineInformation ::
     Module
  -> Maybe LineInformation
  -> Either (NonEmpty CompileError) TypedModule
checkModuleWithLineInformation (Module topLevels) possibleLineInformation =
  let initialState :: CompileState
      initialState =
        (CompileState
           { typeLambdas = []
           , errors = []
           , typedDeclarations = []
           , typeConstructors = Map.empty
           , types = defaultTypes
           })
      lineInformation = fromMaybe (LineInformation Map.empty Map.empty) possibleLineInformation
      compileState :: CompileState
      compileState = foldl (checkTopLevel lineInformation) initialState topLevels
      possibleErrors :: Maybe (NonEmpty CompileError)
      possibleErrors = nonEmpty $ errors compileState
   in case possibleErrors of
        Just errors -> Left errors
        Nothing -> Right (TypedModule (typedDeclarations compileState))

checkModule :: Module -> Either (NonEmpty CompileError) TypedModule
checkModule m = checkModuleWithLineInformation m Nothing

eitherToArrays :: [Either a b] -> Either [a] [b]
eitherToArrays eithers =
  let (lefts, rights) = partitionEithers eithers
   in case lefts of
        [] -> Right rights
        _ -> Left lefts

-- TODO - make this function a bit easier to read
checkDataType :: CompileState -> ADT -> Maybe SourceRange -> CompileState
checkDataType state adt@(ADT name generics constructors) position =
  case (declarationsResult, constructorsResult) of
    (Right declarations, Right constructors) ->
      addTypeConstructors
        (addDeclarations (addTypeLambda state typeLambda) declarations)
        typeLambda
        constructors
    (Left errors, _) -> foldl addError state errors
    (_, Left errors) -> foldl addError state errors
  where
    transformConstructors f =
      eitherToArrays $ (f <$> (zip [0 ..] $ NE.toList constructors))
    declarationsResult :: Either [CompileError] [TypedDeclaration]
    declarationsResult = transformConstructors makeDeclaration
    constructorsResult :: Either [CompileError] [TypedConstructor]
    constructorsResult = transformConstructors makeTypeConstructor
    typeLambda = TypeLambda name
    returnType = foldl Applied (TL typeLambda) (Generic <$> generics)
    makeDeclaration ::
         (Int, Constructor) -> Either CompileError TypedDeclaration
    makeDeclaration (tag, (Constructor name types')) =
      let charToArgument (char, argType) =
            TAIdentifier argType $ ne $ T.singleton char
          argList = maybe (Right []) constructorTypes types'
          arguments = (fmap charToArgument) <$> (zip ['a' ..] <$> argList)
          declarationFromType t typedArgument =
            TypedDeclaration
              name
              typedArgument
              t
              (TypeChecker.ADTConstruction tag typedArgument)
       in declarationFromType <$>
          (maybe (Right returnType) constructorType types') <*>
          arguments
    makeTypeConstructor ::
         (Int, Constructor) -> Either CompileError TypedConstructor
    makeTypeConstructor (tag, (Constructor name types)) =
      TypedConstructor name tag <$> (maybe (Right []) constructorTypes types)
    constructorType :: ConstructorType -> Either CompileError Type
    constructorType ct = foldr Lambda returnType <$> (constructorTypes ct)
    errorMessage = CompileError (DataTypeError adt) position
    constructorTypes :: ConstructorType -> Either CompileError [Type]
    constructorTypes ct =
      case ct of
        CTConcrete identifier ->
          case findTypeFromIdent
                 ((Map.insert name returnType) $ types state)
                 errorMessage
                 identifier of
            Right correctType -> Right [correctType]
            Left e -> Left e
        CTParenthesized (CTApplied (CTConcrete a) (CTConcrete b)) ->
          Right [Applied (TL (TypeLambda a)) (Generic b)]
        CTParenthesized ct -> constructorTypes ct
        CTApplied a b -> (<>) <$> constructorTypes a <*> constructorTypes b

checkTopLevel :: LineInformation -> CompileState -> TopLevel -> CompileState
checkTopLevel lineInformation state topLevel =
  case topLevel of
    DataType adt -> checkDataType state adt position
    Function declaration ->
      let result = checkDeclaration state declaration position exprPosition
       in case result of
            Right t -> addDeclarations state [t]
            Left e -> addError state e
  where
    position = topLevelPosition lineInformation topLevel
    exprPosition = expressionPosition lineInformation

newtype Constraints =
  Constraints (Map Ident Type)
  deriving (Eq, Show)

typeEq :: Type -> Type -> Bool
typeEq a b =
  case typeConstraints a b of
    Just _ -> True
    _ -> False

mergePossibleConstraints :: [Maybe Constraints] -> Maybe Constraints
mergePossibleConstraints mConstraints =
  case mConstraints of
    [] -> Just (Constraints Map.empty)
    (Nothing:_) -> Nothing
    (Just constraints:xs) ->
      mergeConstraints constraints <$> mergePossibleConstraints xs

mergeConstraints :: Constraints -> Constraints -> Constraints
mergeConstraints (Constraints a) (Constraints b) = Constraints (Map.union a b) -- TODO handle clashes

-- you can't treat type a like an int
-- but you can call a function that accepts type a with an int,
-- as long as a is replaced with int in the interpretation of the type of that function
--
-- the rules for application differ from return type checking
--
-- for application, if we have a lambda with a generic value, we should replace that generic with our concrete value on the right
-- for return type checking, we need to be able to understand that we cannot coerce an "a" to a "b"
-- but that we can coerce a "Nothing :: Maybe a" to "Just 5 :: Maybe Int"
--
-- this is possible because the type of Nothing is really forall a. :: Maybe a
-- typeConstraints is currentypeLambday used for both but that's a bad idea, it's only really good at application
typeConstraints :: Type -> Type -> Maybe Constraints
typeConstraints a b =
  case (a, b) of
    (Generic a', _) -> Just (Constraints (Map.insert a' b Map.empty))
    (Applied (TL a') t', Applied (TL b') (Generic g)) ->
      if a' == b'
        then Just (Constraints (Map.insert g t' Map.empty))
        else Nothing
    (Applied a b, Applied a' b') ->
      mergePossibleConstraints [typeConstraints a a', typeConstraints b b']
    (Lambda a b, Lambda x y) ->
      mergePossibleConstraints [typeConstraints a x, typeConstraints b y]
    (a', b') ->
      if a' == b'
        then Just (Constraints Map.empty)
        else Nothing

checkDeclaration ::
     CompileState
  -> Declaration
  -> Maybe SourceRange
  -> (Expression -> Maybe SourceRange)
  -> Either CompileError TypedDeclaration
checkDeclaration state declaration position exprPosition = do
  let (Declaration _ name args expr) = declaration
  annotationTypes <- inferDeclarationType state declaration position
  -- TODO - is sequence right here?
  -- TODO - fix undefined
  argsWithTypes <-
    sequence $
    uncurry (inferArgumentType state undefined) <$>
    zip (NE.toList annotationTypes) args
  let locals = concatMap makeDeclarations argsWithTypes
  expectedReturnType <-
    (case (NE.drop (length args) annotationTypes) of
       (x:xs) -> Right $ collapseTypes (x :| xs)
       _ -> Left $ CompileError (DeclarationError declaration) position "Not enough args")
  let typedDeclaration =
        TypedDeclaration
          name
          argsWithTypes
          (foldr1 Lambda annotationTypes)
          (TypeChecker.Number 0)
  let actualReturnType =
        inferType (addDeclarations state (typedDeclaration : locals)) expr exprPosition
  let typeChecks typedExpression =
        if typeOf typedExpression `typeEq` expectedReturnType -- TODO use typeConstraints here
          then Right $
               TypedDeclaration
                 name
                 argsWithTypes
                 (foldr1 Lambda annotationTypes)
                 typedExpression
          else Left $
               CompileError
                 (DeclarationError declaration)
                 position
                 ("Expected " <> s name <> " to return type " <>
                  printType expectedReturnType <>
                  ", but instead got type " <>
                  printType (typeOf typedExpression))
  actualReturnType >>= typeChecks
  where
    makeDeclarations :: TypedArgument -> [TypedDeclaration]
    makeDeclarations typedArgument =
      case typedArgument of
        TAIdentifier t i -> [makeDeclaration t i]
        TADeconstruction constructor _ args ->
          let declaration = find m (typedDeclarations state)
              m (TypedDeclaration name _ _ _) = name == constructor -- TODO - should probably match on types as well!
              declarations (TypedDeclaration _ _ _ _) =
                concatMap makeDeclarations $ args
           in maybe [] declarations declaration
        TANumberLiteral _ -> []
    makeDeclaration :: Type -> Ident -> TypedDeclaration
    makeDeclaration t i = TypedDeclaration i [] t (TypeChecker.Identifier t i)

lambdaType :: Type -> Type -> [Type] -> Type
lambdaType left right remainder =
  case remainder of
    [] -> Lambda left right
    (x:xs) -> Lambda left (lambdaType right x xs)

typeOf :: TypedExpression -> Type
typeOf t =
  case t of
    TypeChecker.Identifier t _ -> t
    TypeChecker.Apply t _ _ -> t
    TypeChecker.Number _ -> Num
    TypeChecker.Float _ -> Float'
    TypeChecker.Infix t _ _ _ -> t
    TypeChecker.Case t _ _ -> t
    TypeChecker.Let _ te -> typeOf te
    TypeChecker.BetweenParens te -> typeOf te
    TypeChecker.String' _ -> Str
    TypeChecker.ADTConstruction _ _ -> Lambda Num Num -- TODO - make this real

inferApplicationType ::
     CompileState
  -> Expression
  -> Expression
  -> (Expression -> Maybe SourceRange)
  -> (Text -> CompileError)
  -> Either CompileError TypedExpression
inferApplicationType state a b exprPosition compileError =
  let typedExprs =
        (,) <$> inferType state a exprPosition <*>
        inferType state b exprPosition
      inferApplication (a, b) =
        case (typeOf a, typeOf b) of
          (Lambda x r, b') ->
            case typeConstraints x b' of
              Just constraints ->
                Right (TypeChecker.Apply (replaceGenerics constraints r) a b)
              Nothing ->
                Left $
                compileError
                  ("Function expected argument of type " <> printType x <>
                   ", but instead got argument of type " <>
                   printType b')
          _ ->
            Left $
            compileError $
            "Tried to apply a value of type " <> printType (typeOf a) <>
            " to a value of type " <>
            printType (typeOf b)
   in typedExprs >>= inferApplication

inferIdentifierType ::
     CompileState
  -> Ident
  -> (Text -> CompileError)
  -> Either CompileError TypedExpression
inferIdentifierType state name compileError =
  case find (m name) declarations of
    Just (TypedDeclaration _ _ t _) -> Right $ TypeChecker.Identifier t name
    Nothing ->
      Left $
      compileError
        ("It's not clear what \"" <> idToString name <> "\" refers to")
  where
    declarations = typedDeclarations state
    m name (TypedDeclaration name' _ _ _) = name == name'

inferInfixType ::
     CompileState
  -> OperatorExpr
  -> Expression
  -> Expression
  -> (Expression -> Maybe SourceRange)
  -> (Text -> CompileError)
  -> Either CompileError TypedExpression
inferInfixType state op a b exprPosition compileError =
  let validInfix a b =
        case (op, b, typeEq a b) of
          (StringAdd, Str, True) -> Just Str
          (StringAdd, _, _) -> Nothing
          (_, Num, True) -> Just Num
          (_, Float', True) -> Just Float'
          (_, _, _) -> Nothing
      types =
        (,) <$> inferType state a exprPosition <*>
        inferType state b exprPosition
      checkInfix (a, b) =
        case validInfix (typeOf a) (typeOf b) of
          Just returnType -> Right (TypeChecker.Infix returnType op a b)
          Nothing ->
            Left $
            compileError
              ("No function exists with type " <> printType (typeOf a) <> " " <>
               operatorToString op <>
               " " <>
               printType (typeOf b))
   in types >>= checkInfix

inferCaseType ::
     CompileState
  -> Expression
  -> (NonEmpty (Argument, Expression))
  -> (Expression -> Maybe SourceRange)
  -> (Text -> CompileError)
  -> Either CompileError TypedExpression
inferCaseType state value branches exprPosition compileError = do
  typedValue <- inferType state value exprPosition
  typedBranches <- sequence $ inferBranch typedValue <$> branches
  allBranchesHaveSameType typedValue typedBranches
  where
    inferBranch v (a, b) = do
      a' <- inferArgumentType state compileError (typeOf v) a
      let argDeclarations = declarationsFromTypedArgument a'
      b' <- inferType (addDeclarations state argDeclarations) b exprPosition
      return (a', b')
    allBranchesHaveSameType ::
         TypedExpression
      -> NonEmpty (TypedArgument, TypedExpression)
      -> Either CompileError TypedExpression
    allBranchesHaveSameType value types =
      case NE.groupWith (typeOf . snd) types of
        [x] -> Right (TypeChecker.Case (typeOf . snd $ NE.head x) value types)
        -- TODO - there is a bug where we consider Result a b to be equal to Result c d,
        --        failing to recognize the importance of whether a and b have been bound in the signature
        types' ->
          if all
               (\case
                  (x:y:_) -> x `typeEq` y || y `typeEq` x
                  _ -> False)
               (F.toList <$> replicateM 2 (typeOf . snd . NE.head <$> types'))
            then Right
                   (TypeChecker.Case
                      (typeOf . snd $ NE.head (head types'))
                      value
                      types)
            else Left $
                 compileError
                   ("Case expression has multiple return types: " <>
                    T.intercalate
                      ", "
                      (printType <$> NE.toList (typeOf . snd <$> types)))

inferLetType ::
     CompileState
  -> NonEmpty Declaration
  -> Expression
  -> (Expression -> Maybe SourceRange)
  -> (Text -> CompileError)
  -> Either CompileError TypedExpression
inferLetType state declarations' value exprPosition _ =
  let branchTypes ::
           [TypedDeclaration]
        -> [Declaration]
        -> Either CompileError [TypedDeclaration]
      branchTypes typed untyped =
        case untyped of
          [] -> Right []
          (x:xs) ->
            checkDeclaration (addDeclarations state typed) x Nothing exprPosition >>= \t ->
              (:) t <$> branchTypes (typed ++ [t]) xs
   in branchTypes [] (NE.toList declarations') >>= \b ->
        TypeChecker.Let (NE.fromList b) <$>
        inferType (addDeclarations state b) value exprPosition

inferType ::
     CompileState
  -> Expression
  -> (Expression -> Maybe SourceRange)
  -> Either CompileError TypedExpression
inferType state expr exprPosition =
  case expr of
    Language.Number n -> Right $ TypeChecker.Number n
    Language.Float f -> Right $ TypeChecker.Float f
    Language.String' s -> Right $ TypeChecker.String' s
    Language.BetweenParens expr -> inferType state expr exprPosition
    Language.Identifier name ->
      inferIdentifierType state name compileError
    Language.Apply a b ->
      inferApplicationType state a b exprPosition compileError
    Language.Infix op a b ->
      inferInfixType state op a b exprPosition compileError
    Language.Case value branches ->
      inferCaseType state value branches exprPosition compileError
    Language.Let declarations' value ->
      inferLetType state declarations' value exprPosition compileError
  where
    compileError = CompileError (ExpressionError expr) (exprPosition expr)

inferArgumentType ::
     CompileState
  -> (Text -> CompileError)
  -> Type
  -> Argument
  -> Either CompileError TypedArgument
inferArgumentType state err valueType arg =
  case arg of
    AIdentifier i -> Right $ TAIdentifier valueType i
    ANumberLiteral i ->
      if valueType == Num
        then Right $ TANumberLiteral i
        else Left $
             err $
             "case branch is type Int when value is type " <>
             printType valueType
    ADeconstruction name args ->
      let typeLambdaName v =
            case v of
              TL (TypeLambda i) -> Just i
              Applied (TL (TypeLambda i)) _ -> Just i
              Applied a _ -> typeLambdaName a
              _ -> Nothing
          typeLambda =
            typeLambdaName valueType >>=
            (\typeLambdaName ->
               find
                 (\(TypeLambda name') -> typeLambdaName == name')
                 (typeLambdas state))
          constructorsForValue =
            typeLambda >>= flip Map.lookup (typeConstructors state)
          matchingConstructor =
            find (m name) (fromMaybe [] constructorsForValue)
          m name (TypedConstructor name' _ _) = name == name'
          deconstructionFields fields =
            sequence $
            (\(a, t) -> inferArgumentType state err t a) <$> zip args fields
       in case matchingConstructor of
            Just (TypedConstructor name tag fields) ->
              if length args == length fields
                then TADeconstruction name tag <$> deconstructionFields fields
                else Left $
                     err $
                     "Expected " <> s name <> " to have " <> showT (fields) <>
                     " fields, instead found " <>
                     showT (args) <>
                     " arg: " <>
                     showT (arg)
                     -- TODO - make this error message prettier
            Nothing ->
              Left $
              err $
              "no constructor named \"" <> s name <> "\" for " <>
              printType valueType <>
              " in scope."

inferDeclarationType ::
     CompileState
  -> Declaration
  -> Maybe SourceRange
  -> Either CompileError (NE.NonEmpty Type)
inferDeclarationType state declaration lineInformation =
  case annotation of
    Just (Annotation _ types) -> sequence $ annotationTypeToType <$> types
    Nothing -> Left $ compileError "For now, annotations are required."
  where
    (Declaration annotation _ _ _) = declaration
    compileError :: Text -> CompileError
    compileError = CompileError (DeclarationError declaration) lineInformation
    annotationTypeToType t =
      case t of
        Concrete i -> findTypeFromIdent (types state) compileError i
        Parenthesized types -> reduceTypes types
        TypeApplication a b -> inferTypeApplication a b
      where
        m name (TypeLambda name') = name == name'
        inferTypeApplication ::
             AnnotationType -> AnnotationType -> Either CompileError Type
        inferTypeApplication a b =
          case a of
            Concrete i ->
              case find (m i) (typeLambdas state) of
                Just typeLambda ->
                  Applied (TL typeLambda) <$> annotationTypeToType b
                Nothing ->
                  Left $
                  compileError $ "Could not find type lambda: " <> idToString i
            Parenthesized a' ->
              Applied <$> reduceTypes a' <*> annotationTypeToType b
            TypeApplication a' b' ->
              Applied <$> inferTypeApplication a' b' <*> annotationTypeToType b
    reduceTypes :: NE.NonEmpty AnnotationType -> Either CompileError Type
    reduceTypes types =
      collapseTypes <$> sequence (annotationTypeToType <$> types)

collapseTypes :: NE.NonEmpty Type -> Type
collapseTypes = foldr1 Lambda

declarationsFromTypedArgument :: TypedArgument -> [TypedDeclaration]
declarationsFromTypedArgument ta =
  case ta of
    TAIdentifier t n -> [TypedDeclaration n [] t (TypeChecker.Number 0)]
    TANumberLiteral _ -> []
    TADeconstruction _ _ args -> concatMap declarationsFromTypedArgument args

findTypeFromIdent ::
     Map Ident Type
  -> (Text -> CompileError)
  -> Ident
  -> Either CompileError Type
findTypeFromIdent types compileError ident =
  if T.toLower i == i
    then Right $ Generic ident
    else case Map.lookup ident types of
           Just t -> Right t
           Nothing ->
             Left $ compileError $ "Could not find type " <> s ident <> "."
  where
    i = s ident

printType :: Type -> Text
printType t =
  case t of
    Str -> "String"
    Num -> "Int"
    Float' -> "Float"
    Lambda a r -> printType a <> " -> " <> printType r
    Applied a b -> printType a <> " " <> printType b
    Generic n -> idToString n
    TL (TypeLambda typeLambda) -> idToString typeLambda

printSignature :: [Type] -> Text
printSignature types = T.intercalate " -> " (printType <$> types)

mapType :: (Type -> Type) -> Type -> Type
mapType f t =
  case t of
    Num -> f t
    Float' -> f t
    Str -> f t
    Lambda a b -> f (Lambda (mapType f a) (mapType f b))
    Applied typeLambda t -> f (Applied typeLambda (mapType f t))
    Generic _ -> f t
    TL _ -> f t

replaceGenerics :: Constraints -> Type -> Type
replaceGenerics (Constraints constraints) t =
  Map.foldrWithKey replaceGeneric t constraints

replaceGeneric :: Ident -> Type -> Type -> Type
replaceGeneric name newType =
  mapType
    (\case
       Generic n
         | n == name -> newType
       other -> other)

ne :: Text -> Ident
ne s = Ident $ NonEmptyString (T.head s) (T.tail s)
