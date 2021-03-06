{-# LANGUAGE ConstraintKinds, FlexibleContexts, MonadComprehensions, OverloadedStrings, TupleSections, ViewPatterns #-}
module Elaboration.Normalise where

import Protolude hiding (TypeRep)

import qualified Data.HashSet as HashSet
import qualified Data.List.NonEmpty as NonEmpty
import qualified Data.Vector as Vector

import Elaboration.MetaVar.Zonk
import qualified Builtin.Names as Builtin
import Driver.Query
import Effect
import qualified Effect.Context as Context
import Effect.Log as Log
import Elaboration.MetaVar
import Elaboration.Monad
import Syntax
import Syntax.Core
import TypeRep(TypeRep)
import qualified TypeRep
import Util

type MonadNormalise meta m = (MonadIO m, MonadFetch Query m, MonadFresh m, MonadContext (Expr meta Var) m, MonadLog m, MonadReport m)

data Args meta m = Args
  { _expandTypeReps :: !Bool
    -- ^ Should types be reduced to type representations (i.e. forget what the
    -- type is and only remember its representation)?
  , _prettyExpr :: !(Expr meta Var -> m Doc)
  , _handleMetaVar :: !(meta -> m (Maybe (Closed (Expr meta))))
    -- ^ Allows whnf to try to solve unsolved class constraints when they're
    -- encountered.
  }

metaVarSolutionArgs
  :: (MonadContext e m, MonadIO m, MonadLog m)
  => Args MetaVar m
metaVarSolutionArgs = Args
  { _expandTypeReps = False
  , _prettyExpr = prettyMeta <=< zonk
  , _handleMetaVar = solution
  }

expandTypeRepsArgs
  :: (MonadContext e m, MonadIO m, MonadLog m)
  => Args MetaVar m
expandTypeRepsArgs = metaVarSolutionArgs
  { _expandTypeReps = True
  }

voidArgs :: MonadContext e m => Args Void m
voidArgs = Args
  { _expandTypeReps = False
  , _prettyExpr = fmap pretty . mapM prettyVar
  , _handleMetaVar = absurd
  }

-------------------------------------------------------------------------------
-- * Weak head normal forms
whnf
  :: MonadNormalise MetaVar m
  => CoreM
  -> m CoreM
whnf expr = whnf' metaVarSolutionArgs expr mempty

whnf'
  :: MonadNormalise meta m
  => Args meta m
  -> Expr meta Var -- ^ Expression to normalise
  -> [(Plicitness, Expr meta Var)] -- ^ Arguments to the expression
  -> m (Expr meta Var)
whnf' args expr exprs = Log.indent $ do
  logPretty "tc.whnf.context" "context" $ Context.prettyContext $ _prettyExpr args
  logPretty "tc.whnf" "whnf e" $ _prettyExpr args $ apps expr exprs
  res <- normaliseBuiltins go expr exprs
  logPretty "tc.whnf" "whnf res" $ _prettyExpr args res
  return res
  where
    go e@(Var v) es = do
      Context.Binding _ _ _ maybeValue <- Context.lookup v
      case maybeValue of
        Nothing -> return $ apps e es
        Just e' -> do
          minlined <- normaliseDef whnf0 e' es
          case minlined of
            Nothing -> return $ apps e es
            Just (inlined, es') -> whnf' args inlined es'
    go (Meta m mes) es = do
      sol <- _handleMetaVar args m
      case sol of
        Nothing -> do
          mes' <- mapM (mapM whnf0) mes
          es' <- mapM (mapM whnf0) es
          return $ apps (Meta m mes') es'
        Just e' -> whnf' args (open e') $ toList mes ++ es
    go e@(Global g) es = do
      d <- fetchDefinition g
      case d of
        ConstantDefinition Concrete e' -> do
          minlined <- normaliseDef whnf0 e' es
          case minlined of
            Nothing -> return $ apps e es
            Just (inlined, es') -> whnf' args inlined es'
        ConstantDefinition Abstract _ -> return $ apps e es
        DataDefinition _ rep
          | _expandTypeReps args -> do
            minlined <- normaliseDef whnf0 rep es
            case minlined of
              Nothing -> return $ apps e es
              Just (inlined, es') -> whnf' args inlined es'
          | otherwise -> return $ apps e es
    go e@(Con _) es = return $ apps e es
    go e@(Lit _) es = return $ apps e es
    go e@Pi {} es = return $ apps e es
    go (Lam _ p1 _ s) ((p2, e):es) | p1 == p2 = whnf' args (Util.instantiate1 e s) es
    go e@Lam {} es = return $ apps e es
    go (App e1 p e2) es = whnf' args e1 $ (p, e2) : es
    go (Let ds scope) es =
      instantiateLetM ds scope $ \e ->
        whnf' args e es
    go (Case e brs retType) es = do
      e' <- whnf0 e
      case chooseBranch e' brs of
        Nothing -> return $ apps (Case e' brs retType) es
        Just chosen -> whnf' args chosen es
    go (ExternCode c retType) es = do
      c' <- mapM whnf0 c
      retType' <- whnf0 retType
      return $ apps (ExternCode c' retType') es
    go (SourceLoc _ e) es = whnf' args e es

    whnf0 e = whnf' args e mempty

normalise
  :: MonadNormalise MetaVar m
  => CoreM
  -> m CoreM
normalise e = normalise' metaVarSolutionArgs e mempty

normalise'
  :: MonadNormalise meta m
  => Args meta m
  -> Expr meta Var -- ^ Expression to normalise
  -> [(Plicitness, Expr meta Var)] -- ^ Arguments to the expression
  -> m (Expr meta Var)
normalise' args = normaliseBuiltins go
  where
    go e@(Var v) es = do
      Context.Binding _ _ _ maybeValue <- Context.lookup v
      case maybeValue of
        Nothing -> irreducible e es
        Just e' -> do
          minlined <- normaliseDef normalise0 e' es
          case minlined of
            Nothing -> irreducible e es
            Just (inlined, es') -> normalise' args inlined es'
    go (Meta m mes) es = do
      msol <- _handleMetaVar args m
      case msol of
        Nothing -> do
          mes' <- mapM (mapM normalise0) mes
          irreducible (Meta m mes') es
        Just e -> normalise' args (open e) $ toList mes ++ es
    go e@(Global g) es = do
      d <- fetchDefinition g
      case d of
        ConstantDefinition Concrete e' -> do
          minlined <- normaliseDef normalise0 e' es
          case minlined of
            Nothing -> irreducible e es
            Just (inlined, es') -> normalise' args inlined es'
        ConstantDefinition Abstract _ -> irreducible e es
        DataDefinition _ rep
          | _expandTypeReps args -> do
            minlined <- normaliseDef normalise0 rep es
            case minlined of
              Nothing -> irreducible e es
              Just (inlined, es') -> normalise' args inlined es'
          | otherwise -> irreducible e es
    go e@(Con _) es = irreducible e es
    go e@(Lit _) es = irreducible e es
    go (Pi h p t s) es = normaliseScope pi_ h p t s es
    -- TODO sharing
    go (Lam _ p1 _ s) ((p2, e):es) | p1 == p2 = normalise' args (Util.instantiate1 e s) es
    go (Lam h p t s) es = normaliseScope lam h p t s es
    go (App e1 p e2) es = normalise' args e1 ((p, e2) : es)
    go (Let ds scope) es =
      instantiateLetM ds scope $ \e ->
        normalise' args e es
    go (Case e brs retType) es = do
      e' <- normalise0 e
      case chooseBranch e' brs of
        Nothing -> do
          retType' <- normalise0 retType
          brs' <- case brs of
            ConBranches cbrs -> ConBranches
              <$> sequence
                [ normaliseConBranch qc tele s
                | ConBranch qc tele s <- cbrs
                ]
            LitBranches lbrs def -> LitBranches
              <$> sequence [LitBranch l <$> normalise0 br | LitBranch l br <- lbrs]
              <*> normalise0 def
          irreducible (Case e' brs' retType') es
        Just chosen -> normalise' args chosen es
    go (ExternCode c retType) es = do
      c' <- mapM normalise0 c
      retType' <- normalise0 retType
      irreducible (ExternCode c' retType') es
    go (SourceLoc _ e) es = normalise' args e es

    irreducible e es = apps e <$> mapM (mapM normalise0) es

    normaliseConBranch qc tele scope =
      teleMapExtendContext tele normalise0 $ \vs -> do
        e' <- normalise0 $ instantiateTele pure vs scope
        conBranch qc vs e'

    normaliseScope c h p t s es = do
      t' <- normalise0 t
      Context.freshExtend (binding h p t') $ \x -> do
        e <- normalise0 $ Util.instantiate1 (pure x) s
        s' <- c x e
        irreducible s' es

    normalise0 e = normalise' args e mempty

normaliseBuiltins
  :: Monad m
  => (Expr meta v -> [(Plicitness, Expr meta v)] -> m (Expr meta v))
  -> Expr meta v
  -> [(Plicitness, Expr meta v)]
  -> m (Expr meta v)
normaliseBuiltins k (Builtin.QGlobal Builtin.ProductTypeRepName) [(Explicit, x), (Explicit, y)] = typeRepBinOp
  (Just TypeRep.UnitRep) (Just TypeRep.UnitRep)
  TypeRep.product Builtin.ProductTypeRep
  k x y
normaliseBuiltins k (Builtin.QGlobal Builtin.SumTypeRepName) [(Explicit, x), (Explicit, y)] = typeRepBinOp
  (Just TypeRep.UnitRep) (Just TypeRep.UnitRep)
  TypeRep.sum Builtin.SumTypeRep
  k x y
normaliseBuiltins k (Builtin.QGlobal Builtin.SubIntName) [(Explicit, x), (Explicit, y)] =
  binOp Nothing (Just 0) (-) Builtin.SubInt k x y
normaliseBuiltins k (Builtin.QGlobal Builtin.AddIntName) [(Explicit, x), (Explicit, y)] =
  binOp (Just 0) (Just 0) (+) Builtin.AddInt k x y
normaliseBuiltins k (Builtin.QGlobal Builtin.MaxIntName) [(Explicit, x), (Explicit, y)] =
  binOp (Just 0) (Just 0) max Builtin.MaxInt k x y
normaliseBuiltins k e@(Builtin.QGlobal Builtin.MkTypeName) [(Explicit, x)] = do
  x' <- k x mempty
  case x' of
    Lit (Integer i) -> return $ MkType $ TypeRep.TypeRep i
    _ -> return $ App e Explicit x'
normaliseBuiltins k (Lit (Natural 0)) es = k Builtin.Zero es
normaliseBuiltins k (Lit (Natural n)) es = k (Builtin.Succ $ Lit $ Natural $ n - 1) es
normaliseBuiltins k (SourceLoc _ e) es = normaliseBuiltins k e es
normaliseBuiltins k e es = k e es

binOp
  :: Monad m
  => Maybe Integer
  -> Maybe Integer
  -> (Integer -> Integer -> Integer)
  -> (Expr meta v -> Expr meta v -> Expr meta v)
  -> (Expr meta v -> [(Plicitness, Expr meta v)] -> m (Expr meta v))
  -> Expr meta v
  -> Expr meta v
  -> m (Expr meta v)
binOp lzero rzero op cop k x y = do
  x' <- normaliseBuiltins k x mempty
  y' <- normaliseBuiltins k y mempty
  case (x', y') of
    (Lit (Integer m), _) | Just m == lzero -> return y'
    (_, Lit (Integer n)) | Just n == rzero -> return x'
    (Lit (Integer m), Lit (Integer n)) -> return $ Lit $ Integer $ op m n
    _ -> return $ cop x' y'

typeRepBinOp
  :: Monad m
  => Maybe TypeRep
  -> Maybe TypeRep
  -> (TypeRep -> TypeRep -> TypeRep)
  -> (Expr meta v -> Expr meta v -> Expr meta v)
  -> (Expr meta v -> [(Plicitness, Expr meta v)] -> m (Expr meta v))
  -> Expr meta v
  -> Expr meta v
  -> m (Expr meta v)
typeRepBinOp lzero rzero op cop k x y = do
  x' <- normaliseBuiltins k x mempty
  y' <- normaliseBuiltins k y mempty
  case (x', y') of
    (MkType m, _) | Just m == lzero -> return y'
    (_, MkType n) | Just n == rzero -> return x'
    (MkType m, MkType n) -> return $ MkType $ op m n
    _ -> return $ cop x' y'

chooseBranch
  :: Expr meta v
  -> Branches (Expr meta) v
  -> Maybe (Expr meta v)
chooseBranch (Lit l) (LitBranches lbrs def) = Just chosenBranch
  where
    chosenBranch = fromMaybe def $ head [br | LitBranch l' br <- NonEmpty.toList lbrs, l == l']
chooseBranch (appsView -> (Con qc, args)) (ConBranches cbrs) =
  Just $ instantiateTele snd (Vector.drop (Vector.length argsv - numConArgs) argsv) chosenBranch
  where
    argsv = Vector.fromList args
    (numConArgs, chosenBranch) = case [(teleLength tele, br) | ConBranch qc' tele br <- cbrs, qc == qc'] of
      [br] -> br
      _ -> panic "Normalise.chooseBranch"
chooseBranch _ _ = Nothing

-- | Definition normalisation heuristic:
--
-- If a definition is of the form `f = \xs. cases`, we inline `f` during the
-- normalisation of `f es` if:
--
-- The application is saturated, i.e. `length es >= length xs`, and the
-- (possibly nested) case expressions `cases` reduce to something that doesn't
-- start with a case.
--
-- This is done to avoid endlessly unfolding recursive definitions. It means
-- that it's possible to miss some definitional equalities, but this is
-- hopefully rarely the case in practice.
normaliseDef
  :: MonadReport m
  => (Expr meta Var -> m (Expr meta Var)) -- ^ How to normalise case scrutinees
  -> Expr meta Var -- ^ The definition
  -> [(Plicitness, Expr meta Var)] -- ^ Arguments
  -> m (Maybe (Expr meta Var, [(Plicitness, Expr meta Var)]))
  -- ^ The definition body applied to some arguments and any arguments that are still left
normaliseDef norm = lambdas
  where
    lambdas (SourceLoc loc e) es = located loc $ lambdas e es
    lambdas (Lam _ p2 _ s) ((p1, e):es) | p1 == p2 = lambdas (instantiate1 e s) es
    lambdas Lam {} [] = return Nothing
    lambdas e es = do
      mresult <- cases e
      return $ (, es) <$> mresult
    cases (SourceLoc loc e) = located loc $ cases e
    cases (Case e brs _retType) = do
      e' <- norm e
      case chooseBranch e' brs of
        Nothing -> return Nothing
        Just chosen -> cases chosen
    cases e = return $ Just e

instantiateLetM
  :: (MonadContext (Expr meta Var) m, MonadFresh m)
  => LetRec (Expr meta) Var
  -> Scope LetVar (Expr meta) Var
  -> (Expr meta Var -> m (Expr meta Var))
  -> m (Expr meta Var)
instantiateLetM ds scope k =
  Context.freshExtends (forLet ds $
    \h _ _ t -> binding h Explicit t) $ \vs ->
  Context.sets (Vector.zip vs $ foreach (letBodies ds) $ instantiateLet pure vs) $ do
    result <- k $ instantiateLet pure vs scope
    let
      varSet = toHashSet vs
    ctx <- getContext
    return $ result >>= \v ->
      case (v `HashSet.member` varSet, Context.lookupValue v ctx) of
        (True, Just e) -> e
        _ -> pure v

etaReduce :: Expr meta v -> Maybe (Expr meta v)
etaReduce (Lam _ p _ (Scope (App e1scope p' (Var (B ())))))
  | p == p', Just e1' <- unusedScope $ Scope e1scope = Just e1'
etaReduce _ = Nothing
