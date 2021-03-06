{-# LANGUAGE GeneralizedNewtypeDeriving #-}
module Syntax.Name where

import Protolude

import Data.Text(Text)

import Util

newtype Name = Name Text
  deriving (Eq, Hashable, Ord, Show, IsString, Semigroup, Monoid)

fromName :: IsString a => Name -> a
fromName (Name t) = fromText t

newtype Constr = Constr Text
  deriving (Eq, Hashable, Ord, Show, IsString, Semigroup, Monoid)

fromConstr :: IsString a => Constr -> a
fromConstr (Constr t) = fromText t
