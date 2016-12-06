{-# LANGUAGE TypeFamilies, ScopedTypeVariables, TypeFamilyDependencies #-}
{-# LANGUAGE GADTs, AllowAmbiguousTypes, UndecidableInstances #-}
{-# LANGUAGE MultiParamTypeClasses, RankNTypes #-}
{-# LANGUAGE FlexibleInstances, TypeOperators, TypeApplications, TypeInType #-}
{-# LANGUAGE OverloadedLabels, MagicHash #-}

module GraphQL.MuckTom where

-- TODO (probably incomplete, the spec is large)
-- * input objects - I'm not super clear from the spec on how
--   they differ from normal objects.
-- * "extend type X" is used in examples in the spec but it's not
--   explained anywhere?
-- * Directives (https://facebook.github.io/graphql/#sec-Type-System.Directives)
-- * Enforce non-empty lists (might only be doable via value-level validation)

import qualified Prelude
import GraphQL.Schema hiding (Type)
import qualified GraphQL.Schema (Type)
import Protolude hiding (Enum)
import GHC.TypeLits (Symbol, KnownSymbol, symbolVal)
import qualified GHC.TypeLits (TypeError, ErrorMessage(..))

import qualified GraphQL.Value as Value
import qualified Data.Map as M

-- | Argument operator.
data a :> b = a :> b
infixr 8 :>

  -- | Object result operator.
data a :<> b = a :<> b
infixr 8 :<>


data Object (name :: Symbol) (interfaces :: [Type]) (fields :: [Type])
data Enum (name :: Symbol) (values :: [Symbol])
data Union (name :: Symbol) (types :: [Type])
data List (elemType :: Type)

-- TODO(tom): AFACIT We can't constrain "fields" to e.g. have at least
-- one field in it - is this a problem?
data Interface (name :: Symbol) (fields :: [Type])
data Field (name :: Symbol) (fieldType :: Type)
data Argument (name :: Symbol) (argType :: Type)


-- Can't set the value for default arguments via types, but can
-- distinguish to force users to provide a default argument somewhere
-- in their function (using Maybe? ore some new type like
-- https://hackage.haskell.org/package/optional-args-1.0.1)
data DefaultArgument (name :: Symbol) (argType :: Type)


-- Transform into a Schema definition
class HasObjectDefinition a where
  -- Todo rename to getObjectTypeDefinition
  getDefinition :: ObjectTypeDefinition

class HasFieldDefinition a where
  getFieldDefinition :: FieldDefinition


-- Fields
class HasFieldDefinitions a where
  getFieldDefinitions :: [FieldDefinition]

instance forall a as. (HasFieldDefinition a, HasFieldDefinitions as) => HasFieldDefinitions (a:as) where
  getFieldDefinitions = (getFieldDefinition @a):(getFieldDefinitions @as)

instance HasFieldDefinitions '[] where
  getFieldDefinitions = []

-- symbols
class GetSymbolList a where
  getSymbolList :: [Prelude.String]

instance forall a as. (KnownSymbol a, GetSymbolList as) => GetSymbolList (a:as) where
  getSymbolList = (symbolVal (Proxy :: Proxy a)):(getSymbolList @as)

instance GetSymbolList '[] where
  getSymbolList = []


-- object types from union type lists, e.g. for
-- Union "Horse" '[Leg, Head, Tail]
--               ^^^^^^^^^^^^^^^^^^ this part
class UnionTypeObjectTypeDefinitionList a where
  getUnionTypeObjectTypeDefinitions :: [ObjectTypeDefinition]

instance forall a as. (HasObjectDefinition a, UnionTypeObjectTypeDefinitionList as) => UnionTypeObjectTypeDefinitionList (a:as) where
  getUnionTypeObjectTypeDefinitions = (getDefinition @a):(getUnionTypeObjectTypeDefinitions @as)

instance UnionTypeObjectTypeDefinitionList '[] where
  getUnionTypeObjectTypeDefinitions = []


-- Interfaces
class HasInterfaceDefinitions a where
  getInterfaceDefinitions :: Interfaces

instance forall a as. (HasInterfaceDefinition a, HasInterfaceDefinitions as) => HasInterfaceDefinitions (a:as) where
  getInterfaceDefinitions = (getInterfaceDefinition @a):(getInterfaceDefinitions @as)

instance HasInterfaceDefinitions '[] where
  getInterfaceDefinitions = []

class HasInterfaceDefinition a where
  getInterfaceDefinition :: InterfaceTypeDefinition

instance forall ks fields. (KnownSymbol ks, HasFieldDefinitions fields) => HasInterfaceDefinition (Interface ks fields) where
  getInterfaceDefinition =
    let name = Name (toS (symbolVal (Proxy :: Proxy ks)))
        in InterfaceTypeDefinition name (NonEmptyList (getFieldDefinitions @fields))

-- Give users some help if they don't terminate Arguments with a Field:
-- NB the "redundant constraints" warning is a GHC bug: https://ghc.haskell.org/trac/ghc/ticket/11099
instance forall ks t. GHC.TypeLits.TypeError ('GHC.TypeLits.Text ":> Arguments must end with a Field") =>
         HasFieldDefinition (Argument ks t) where
  getFieldDefinition = undefined

instance forall ks is ts. (KnownSymbol ks, HasInterfaceDefinitions is, HasFieldDefinitions ts) => HasAnnotatedType (Object ks is ts) where
  getAnnotatedType =
    let obj = getDefinition @(Object ks is ts)
    in TypeNamed (DefinedType (TypeDefinitionObject obj))

instance forall t ks. (KnownSymbol ks, HasAnnotatedType t) => HasFieldDefinition (Field ks t) where
  getFieldDefinition =
    let name = Name (toS (symbolVal (Proxy :: Proxy ks)))
    in FieldDefinition name [] (getAnnotatedType @t)


instance forall ks t b. (KnownSymbol ks, HasAnnotatedInputType t, HasFieldDefinition b) => HasFieldDefinition ((Argument ks t) :> b) where
  getFieldDefinition =
    let (FieldDefinition name argDefs at) = getFieldDefinition @b
        argName = Name (toS (symbolVal (Proxy :: Proxy ks)))
        arg = ArgumentDefinition argName (getAnnotatedInputType @t) Nothing
    in (FieldDefinition name (arg:argDefs) at)


instance forall ks is fields.
  (KnownSymbol ks, HasInterfaceDefinitions is, HasFieldDefinitions fields) =>
  HasObjectDefinition (Object ks is fields) where
  getDefinition =
    let name = Name (toS (symbolVal (Proxy :: Proxy ks)))
    in ObjectTypeDefinition name (getInterfaceDefinitions @is) (NonEmptyList (getFieldDefinitions @fields))

-- Builtin output types (annotated types)
class HasAnnotatedType a where
  -- TODO - the fact that we have to return TypeNonNull for normal
  -- types will amost certainly lead to bugs because people will
  -- forget this. Maybe we can flip the internal encoding to be
  -- non-null by default and needing explicit null-encoding (via
  -- Maybe).
  getAnnotatedType :: AnnotatedType GraphQL.Schema.Type

instance forall a. HasAnnotatedType a => HasAnnotatedType (Maybe a) where
  -- see TODO in HasAnnotatedType class
  getAnnotatedType =
    let TypeNonNull (NonNullTypeNamed t) = getAnnotatedType @a
    in TypeNamed t

instance HasAnnotatedType Int where
  getAnnotatedType = (TypeNonNull . NonNullTypeNamed . BuiltinType) GInt

instance HasAnnotatedType Bool where
  getAnnotatedType = (TypeNonNull . NonNullTypeNamed . BuiltinType) GBool

instance HasAnnotatedType Text where
  getAnnotatedType = (TypeNonNull . NonNullTypeNamed . BuiltinType) GString

instance HasAnnotatedType Double where
  getAnnotatedType = (TypeNonNull . NonNullTypeNamed . BuiltinType) GFloat

instance HasAnnotatedType Float where
  getAnnotatedType = (TypeNonNull . NonNullTypeNamed . BuiltinType) GFloat

instance forall t. (HasAnnotatedType t) => HasAnnotatedType (List t) where
  getAnnotatedType = TypeList (ListType (getAnnotatedType @t))

instance forall ks sl. (KnownSymbol ks, GetSymbolList sl) => HasAnnotatedType (Enum ks sl) where
  getAnnotatedType =
    let name = Name (toS (symbolVal (Proxy :: Proxy ks)))
        et = EnumTypeDefinition name (map (EnumValueDefinition . Name . toS) (getSymbolList @sl))
    in TypeNonNull (NonNullTypeNamed (DefinedType (TypeDefinitionEnum et)))

instance forall ks as. (KnownSymbol ks, UnionTypeObjectTypeDefinitionList as) => HasAnnotatedType (Union ks as) where
  getAnnotatedType =
    let name = Name (toS (symbolVal (Proxy :: Proxy ks)))
        types = NonEmptyList (getUnionTypeObjectTypeDefinitions @as)
    in TypeNamed (DefinedType (TypeDefinitionUnion (UnionTypeDefinition name types)))

-- Help users with better type errors
instance GHC.TypeLits.TypeError ('GHC.TypeLits.Text "Cannot encode Integer because it has arbitrary size but the JSON encoding is a number") =>
         HasAnnotatedType Integer where
  getAnnotatedType = undefined


-- Builtin input types
class HasAnnotatedInputType a where
  -- See TODO comment in "HasAnnotatedType" class for nullability.
  getAnnotatedInputType :: AnnotatedType InputType

instance forall a. HasAnnotatedInputType a => HasAnnotatedInputType (Maybe a) where
  getAnnotatedInputType =
    let TypeNonNull (NonNullTypeNamed t) = getAnnotatedInputType @a
    in TypeNamed t

instance HasAnnotatedInputType Int where
  getAnnotatedInputType = (TypeNonNull . NonNullTypeNamed . BuiltinInputType) GInt

instance HasAnnotatedInputType Bool where
  getAnnotatedInputType = (TypeNonNull . NonNullTypeNamed . BuiltinInputType) GBool

instance HasAnnotatedInputType Text where
  getAnnotatedInputType = (TypeNonNull . NonNullTypeNamed . BuiltinInputType) GString

instance HasAnnotatedInputType Double where
  getAnnotatedInputType = (TypeNonNull . NonNullTypeNamed . BuiltinInputType) GFloat

instance HasAnnotatedInputType Float where
  getAnnotatedInputType = (TypeNonNull . NonNullTypeNamed . BuiltinInputType) GFloat

instance forall t. (HasAnnotatedInputType t) => HasAnnotatedInputType (List t) where
  getAnnotatedInputType = TypeList (ListType (getAnnotatedInputType @t))

instance forall ks sl. (KnownSymbol ks, GetSymbolList sl) => HasAnnotatedInputType (Enum ks sl) where
  getAnnotatedInputType =
    let name = Name (toS (symbolVal (Proxy :: Proxy ks)))
        et = EnumTypeDefinition name (map (EnumValueDefinition . Name . toS) (getSymbolList @sl))
    in TypeNonNull (NonNullTypeNamed (DefinedInputType (InputTypeDefinitionEnum et)))


-- How would we build handlers?
-- constraints
-- * impossible to make mistakes
--   - that excludes callback because we could forget to callback
--   - unless we can figure out a way to return a unique value from callback?
-- * no super-crazy type magic

--   - that excludes vinyl
-- * nested tuples make it hard to write single-tuple entries (Identity or Only like in postgresql-simple could work?)
--   - nested tuples need unpacking to be usable
--   - could do sth isomorphic to nested tuples (e.g. with type operators like :<>)

-- On returning
-- A: pure (10 :<> 20)
-- B: pure 10 :<> pure 20
--
-- Only solution B allows us to only run actions when the user
-- requested them. It's more to write though!

type family FieldName (a :: Type) :: Symbol
type instance FieldName (Field ks t) = ks
type instance FieldName (Argument a0 a1 :> a) = FieldName a

-- simple text placeholder query for now
type QueryTerm = Text
type QueryArgs = [Text]
type Query = [QueryTerm] -- also know as a `SelectionSet`

class HasGraph a where
  type HandlerType a
  buildResolver :: HandlerType a -> Query -> IO Value.Value

-- TODO not super hot on individual values having to be instances of
-- HasGraph but not sure how else we can nest either types or
-- (Object _ _ fields). Maybe instead of field we need a "SubObject"?
instance HasGraph Int32 where
  type HandlerType Int32 = IO Int32
  -- TODO check that selectionset is empty (we expect a terminal node)
  buildResolver handler _ =  fmap Value.toValue handler

instance HasGraph Double where
  type HandlerType Double = IO Double
  -- TODO check that selectionset is empty (we expect a terminal node)
  buildResolver handler _ =  fmap Value.toValue handler

-- Parse a value of the right type from an argument
class ReadValue a where
  readValue :: QueryArgs -> a

instance ReadValue Int where
  readValue _ = 14

instance ReadValue Int32 where
  readValue _ = 32

instance ReadValue Double where
  readValue _ = 14.0


class BuildFieldResolver a where
  type FieldHandler a :: Type
  buildFieldResolver :: FieldHandler a -> QueryArgs -> (Text, IO Value.Value)


instance forall ks t. (KnownSymbol ks, HasGraph t) => BuildFieldResolver (Field ks t) where
  type FieldHandler (Field ks t) = HandlerType t
  buildFieldResolver handler queryArgs =
    let childResolver = buildResolver @t handler [] -- need sub query access so can't just pass queryargs
        name = toS (symbolVal (Proxy :: Proxy ks))
    in (name, childResolver)

instance forall ks t f. (KnownSymbol ks, BuildFieldResolver f, ReadValue t) => BuildFieldResolver (Argument ks t :> f) where
  type FieldHandler (Argument ks t :> f) = t -> FieldHandler f
  buildFieldResolver handler queryArgs =
    let partiallyAppliedHandler = handler (readValue @t []) -- need query args access here
    in buildFieldResolver @f partiallyAppliedHandler queryArgs


class RunFields a where
  type RunFieldsType a :: Type
  -- Runfield is run on a single QueryTerm so it can only ever return
  -- one (Text, Value)
  runFields :: RunFieldsType a -> QueryTerm -> IO (Text, Value.Value)


instance forall f fs.
         ( BuildFieldResolver f
         , RunFields fs
         ) => RunFields (f:fs) where
  type RunFieldsType (f:fs) = (FieldHandler f) :<> (RunFieldsType fs)
  -- Deconstruct object type signature and handler value at the same
  -- time and run type-directed code for each field.
  runFields handler@(lh :<> rh) term =
    let (k, valueIO) = buildFieldResolver @f lh [] -- TODO query args
    in case term == k of
      True -> do
        value <- valueIO
        pure (k, value)
      False -> runFields @fs rh term


instance RunFields '[] where
  type RunFieldsType '[] = ()
  -- TODO maybe better to return Either?
  runFields _ term = error ("Query for undefined term:" <> (show term))


-- TODO: arguments. The interpreter
instance forall typeName interfaces fields.
         ( RunFields fields
         ) => HasGraph (Object typeName interfaces fields) where
  type HandlerType (Object typeName interfaces fields) = IO (RunFieldsType fields)

  buildResolver handlerIO query = do
    -- First we run the actual handler function itself in IO.
    handler <- handlerIO
    -- considering that this is an object we'll need to collect (name,
    -- Value) pairs from runFields and build a map with them.

    -- might need https://hackage.haskell.org/package/linkedhashmap to
    -- keep insertion order. (TODO)
    r <- forM query $ \term -> runFields @fields handler term
    pure $ Value.toValue $ M.fromList r


--- test code below
type T = Object "T" '[] '[Field "z" Int32, Argument "t" Int :> Field "t" Int32]

tHandler :: HandlerType T
tHandler = do
  conn <- print @IO @Text "HI"
  pure $ (pure 10) :<> (\tArg -> pure 10) :<> ()

-- hlist :: a -> (a :<> ()) TODO
-- hlist a = a :<> ()

{-
type Calculator = Object "Calculator" '[]
  '[ Argument "a" Int32 :> Argument "b" Int32 :> Field "add" Int32
   , Argument "a" Double :> Field "log" Double
   ]

type API = Object "API" '[] '[Field "calc" Calculator]

type FakeUser = ()

calculatorHandler :: FakeUser -> HandlerType Calculator
calculatorHandler _fakeUser =
  pure (add' :<> log' :<> ())
  where
    add' a b = pure (a + b)
    log' a = pure (log a)

api :: HandlerType API
api = do
  fakeUser <- print @IO @Text "fake lookup user"
  pure (calculatorHandler fakeUser :<> ())
-}