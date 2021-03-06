{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
module Syntax.Sized.Definition where

import Protolude

import Bound hiding (Var)
import Control.Monad.Morph
import Data.Hashable.Lifted
import Data.Vector(Vector)

import Effect.Context as Context
import Pretty
import Syntax.Annotation
import Syntax.GlobalBind
import Syntax.Name
import Syntax.Sized.Anno
import Syntax.Telescope

data Function expr v
  = Function (Telescope expr v) (AnnoScope TeleVar expr v)
  deriving (Eq, Foldable, Functor, Ord, Show, Traversable, Generic, Generic1, Hashable, Hashable1)

newtype Constant expr v
  = Constant (Anno expr v)
  deriving (Eq, Foldable, Functor, Ord, Show, Traversable, Generic, Generic1, Hashable, Hashable1)

data IsClosure
  = NonClosure
  | IsClosure
  deriving (Eq, Ord, Show, Generic, Hashable)

data Definition expr v
  = FunctionDef Visibility IsClosure (Function expr v)
  | ConstantDef Visibility (Constant expr v)
  deriving (Eq, Foldable, Functor, Ord, Show, Traversable, Generic, Generic1, Hashable, Hashable1)

-------------------------------------------------------------------------------
-- Helpers
typedFunction
  :: (Monad expr, MonadContext expr' m)
  => Vector (Var, expr Var)
  -> Anno expr Var
  -> m (Function expr Var)
typedFunction vs e = do
  tele <- varTypeTelescope vs
  return $ Function tele $ abstractAnno (teleAbstraction $ fst <$> vs) e

function
  :: (Monad expr, MonadContext (expr Var) m)
  => Vector Var
  -> Anno expr Var
  -> m (Function expr Var)
function vs e = do
  tele <- varTelescope vs
  return $ Function tele $ abstractAnno (teleAbstraction vs) e

-------------------------------------------------------------------------------
-- Instances
instance MFunctor Constant where
  hoist f (Constant e) = Constant (hoist f e)

instance MFunctor Function where
  hoist f (Function tele s) = Function (hoist f tele) (hoist f s)

instance MFunctor Definition where
  hoist f (FunctionDef vis cl fdef) = FunctionDef vis cl $ hoist f fdef
  hoist f (ConstantDef vis cdef) = ConstantDef vis $ hoist f cdef

instance Bound Constant where
  Constant expr >>>= f = Constant $ expr >>>= f

instance GBound Constant where
  gbound f (Constant expr) = Constant $ gbound f expr

instance Bound Function where
  Function args s >>>= f = Function (args >>>= f) (s >>>= f)

instance GBound Function where
  gbound f (Function args s) = Function (gbound f args) $ gbound f s

instance Bound Definition where
  FunctionDef vis cl fdef >>>= f = FunctionDef vis cl $ fdef >>>= f
  ConstantDef vis cdef >>>= f = ConstantDef vis $ cdef >>>= f

instance GBound Definition where
  gbound f (FunctionDef vis cl fdef) = FunctionDef vis cl $ gbound f fdef
  gbound f (ConstantDef vis cdef) = ConstantDef vis $ gbound f cdef

instance (v ~ Doc, Pretty (expr v), Monad expr) => Pretty (Function expr v) where
  prettyM (Function vs s) = parens `above` absPrec $
    withTeleHints vs $ \ns ->
      "\\" <> prettyTeleVars ns vs <> "." <+>
      associate absPrec (prettyM $ instantiateAnnoTele (pure . fromName) ns s)

instance PrettyAnnotation IsClosure where
  prettyAnnotation IsClosure = prettyTightApp "[]"
  prettyAnnotation NonClosure = identity

instance (v ~ Doc, Pretty (expr v)) => Pretty (Constant expr v) where
  prettyM (Constant e) = prettyM e

instance (v ~ Doc, Pretty (expr v), Monad expr) => Pretty (Definition expr v) where
  prettyM (ConstantDef v c) = prettyM v <+> prettyM c
  prettyM (FunctionDef v cl f) = prettyM v <+> prettyAnnotation cl (prettyM f)
