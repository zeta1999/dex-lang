-- Copyright 2019 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module Subst (Subst, subst, instantiateTVs, abstractTVs) where

import Data.Foldable
import Data.List (elemIndex)

import Env
import Record
import Syntax
import PPrint

class Subst a where
  subst :: (SubstEnv, Scope) -> a -> a

instance (TraversableExpr expr, Subst ty, Subst e, Subst lam)
         => Subst (expr ty e lam) where
  subst env expr = fmapExpr expr (subst env) (subst env) (subst env)

instance Subst Expr where
  subst env@(_, scope) expr = case expr of
    Decl decl body -> Decl decl' (subst (env <> env') body)
      where (decl', env') = refreshDecl scope (subst env decl)
    CExpr e  -> CExpr $ subst env e
    Atom  x  -> Atom  $ subst env x

instance Subst Atom where
  subst env@(sub, scope) atom = case atom of
    Var v -> case envLookup sub v of
      Nothing -> Var $ fmap (subst env) v
      Just (L x') -> subst (mempty, scope) x'
      Just (T _ ) -> error "Expected let-bound variable"
    TLam tvs body -> TLam tvs' $ subst (env <> env') body
      where (tvs', env') = refreshTBinders scope tvs
    Con con -> Con $ subst env con

instance Subst LamExpr where
  subst env@(_, scope) (LamExpr b body) = LamExpr b' body'
    where (b', env') = refreshBinder scope (subst env b)
          body' = subst (env <> env') body

refreshDecl :: Env () -> Decl -> (Decl, (SubstEnv, Scope))
refreshDecl scope decl = case decl of
  Let b bound -> (Let b' bound, env)
    where (b', env) = refreshBinder scope (subst env b)

refreshBinder :: Env () -> Var -> (Var, (SubstEnv, Scope))
refreshBinder scope b = (b', env')
  where b' = rename b scope
        env' = (b@>L (Var b'), b'@>())

refreshTBinders :: Env () -> [TVar] -> ([TVar], (SubstEnv, Scope))
refreshTBinders scope bs = (bs', env')
  where (bs', scope') = renames bs scope
        env' = (fold [b @> T (TypeVar b') | (b,b') <- zip bs bs'], scope')

instance Subst Type where
   subst env@(sub, _) ty = case ty of
    BaseType _ -> ty
    TypeVar v ->
      case envLookup sub v of
        Nothing      -> ty
        Just (T ty') -> ty'
        Just (L _)   -> error $ "Shadowed type var: " ++ pprint v
    ArrowType l a b -> ArrowType (recur l) (recur a) (recur b)
    TabType a b -> TabType (recur a) (recur b)
    ArrayType shape b -> ArrayType shape b
    RecType r   -> RecType $ fmap recur r
    TypeApp f args -> reduceTypeApp (recur f) (map recur args)
    Forall    ks body -> Forall    ks (recur body)
    TypeAlias ks body -> TypeAlias ks (recur body)
    Monad eff a -> Monad (fmap recur eff) (recur a)
    Lens a b    -> Lens (recur a) (recur b)
    IdxSetLit _ -> ty
    BoundTVar _ -> ty
    Mult _      -> ty
    NoAnn       -> NoAnn
    where recur = subst env

instance Subst Decl where
  subst env decl = case decl of
    Let    b    bound -> Let    (subst env b)    (subst env bound)

instance Subst Kind where
  subst _ k = k

instance Subst Var where
  subst env (v:>ty) = v:> subst env ty

instance Subst a => Subst (RecTree a) where
  subst env p = fmap (subst env) p

instance (Subst a, Subst b) => Subst (a, b) where
  subst env (x, y) = (subst env x, subst env y)

instance Subst a => Subst (Env a) where
  subst env xs = fmap (subst env) xs

instance Subst TopEnv where
  subst env (TopEnv e1 e2 e3) = TopEnv (subst env e1) (subst env e2) (subst env e3)

instance (Subst a, Subst b) => Subst (LorT a b) where
  subst env (L x) = L (subst env x)
  subst env (T y) = T (subst env y)

instance (Subst a, Subst b) => Subst (Either a b)where
  subst env (Left  x) = Left  (subst env x)
  subst env (Right x) = Right (subst env x)

-- TODO: check kinds before alias expansion
reduceTypeApp :: Type -> [Type] -> Type
reduceTypeApp (TypeAlias ks ty) xs | length ks == length xs = instantiateTVs xs ty
                                   | otherwise = error "Kind error"
reduceTypeApp f xs = TypeApp f xs

instantiateTVs :: [Type] -> Type -> Type
instantiateTVs vs x = subAtDepth 0 sub x
  where sub depth tvar =
          case tvar of
            Left v -> TypeVar v
            Right i | i >= depth -> if i' < length vs && i >= 0
                                      then vs !! i'
                                      else error $ "Bad index: "
                                             ++ show i' ++ " / " ++ pprint vs
                                             ++ " in " ++ pprint x
                    | otherwise  -> BoundTVar i
              where i' = i - depth

abstractTVs :: [TVar] -> Type -> Type
abstractTVs vs x = subAtDepth 0 sub x
  where sub depth tvar = case tvar of
                           Left v -> case elemIndex (varName v) (map varName vs) of
                                       Nothing -> TypeVar v
                                       Just i  -> BoundTVar (depth + i)
                           Right i -> BoundTVar i

subAtDepth :: Int -> (Int -> Either TVar Int -> Type) -> Type -> Type
subAtDepth d f ty = case ty of
    BaseType _    -> ty
    TypeVar v     -> f d (Left v)
    ArrowType m a b -> ArrowType (recur m) (recur a) (recur b)
    TabType a b   -> TabType (recur a) (recur b)
    RecType r     -> RecType (fmap recur r)
    ArrayType _ _ -> ty
    TypeApp a b   -> TypeApp (recur a) (map recur b)
    Monad eff a   -> Monad (fmap recur eff) (recur a)
    Lens a b      -> Lens (recur a) (recur b)
    Forall    ks body -> Forall    ks (recurWith (length ks) body)
    TypeAlias ks body -> TypeAlias ks (recurWith (length ks) body)
    IdxSetLit _   -> ty
    BoundTVar n   -> f d (Right n)
    Mult l        -> Mult l
    NoAnn         -> NoAnn
  where recur        = subAtDepth d f
        recurWith d' = subAtDepth (d + d') f
