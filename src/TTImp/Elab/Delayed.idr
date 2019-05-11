module TTImp.Elab.Delayed

import Core.CaseTree
import Core.Context
import Core.Core
import Core.Env
import Core.Normalise
import Core.Unify
import Core.TT
import Core.Value

import TTImp.Elab.Check
import TTImp.Elab.ImplicitBind
import TTImp.TTImp

import Data.IntMap

%default covering

-- We run the elaborator in the given environment, but need to end up with a
-- closed term. 
mkClosedElab : FC -> Env Term vars -> 
               (Core (Term vars, Glued vars)) ->
               Core ClosedTerm
mkClosedElab fc [] elab 
    = do (tm, _) <- elab
         pure tm
mkClosedElab {vars = x :: vars} fc (b :: env) elab
    = mkClosedElab fc env 
          (do (sc', _) <- elab
              let b' = newBinder b
              pure (Bind fc x b' sc', gErased fc))
  where
    -- in 'abstractEnvType' we get a Pi binder (so we'll need a Lambda) for
    -- everything except 'Let', so make the appropriate corresponding binder
    -- here
    newBinder : Binder (Term vars) -> Binder (Term vars)
    newBinder (Let c val ty) = Let c val ty
    newBinder b = Lam (multiplicity b) Explicit (binderType b)

-- Try the given elaborator; if it fails, and the error matches the
-- predicate, make a hole and try it again later when more holes might
-- have been resolved
export
delayOnFailure : {auto c : Ref Ctxt Defs} -> 
                 {auto u : Ref UST UState} ->
                 {auto e : Ref EST (EState vars)} -> 
                 FC -> RigCount -> Env Term vars ->
                 (expected : Glued vars) ->
                 (Error -> Bool) ->
                 (Bool -> Core (Term vars, Glued vars)) ->
                 Core (Term vars, Glued vars)
delayOnFailure fc rig env expected pred elab 
    = handle (elab False)
        (\err => 
            do if pred err 
                  then 
                    do nm <- genName "delayed"
                       (ci, dtm) <- newDelayed fc rig env nm !(getTerm expected)
                       logGlue 5 ("Postponing elaborator " ++ show nm ++ 
                                  " for") env expected
                       ust <- get UST
                       put UST (record { delayedElab $= insert ci
                                           (mkClosedElab fc env (elab True)) } 
                                       ust)
                       pure (dtm, expected)
                  else throw err)

export
retryDelayedIn : {auto c : Ref Ctxt Defs} -> 
                 {auto u : Ref UST UState} ->
                 {auto e : Ref EST (EState vars)} -> 
                 Env Term vars -> Term vars -> 
                 Core ()
retryDelayedIn env (Meta fc n i args)
    = do traverse (retryDelayedIn env) args
         defs <- get Ctxt
         case !(lookupDefExact (Resolved i) (gamma defs)) of
              Just Delayed => 
                do ust <- get UST
                   let Just elab = lookup i (delayedElab ust)
                            | Nothing => pure ()
                   tm <- elab
                   -- On success, look for delayed holes in the result
                   retryDelayedIn env (embed tm)
                   updateDef (Resolved i) (const (Just 
                        (PMDef [] (STerm tm) (STerm tm) [])))
                   logTerm 5 ("Resolved delayed hole " ++ show n) tm
                   removeHole i
              -- Also look for delayed names inside guarded definitions.
              -- This helps with error messages because it shows any
              -- problems in delayed elaborators before the constraint
              -- failure, and it might also solve some constraints
              Just (Guess g cs) => retryDelayedIn env (embed g)
              _ => pure ()
retryDelayedIn env (Bind fc x b sc) 
    = do traverse (retryDelayedIn env) b
         inScope fc (b :: env)
                    (\e' => retryDelayedIn {e=e'} (b :: env) sc)
retryDelayedIn env (App fc fn p arg)
    = do retryDelayedIn env fn
         retryDelayedIn env arg
retryDelayedIn env (As fc as pat)
    = do retryDelayedIn env as
         retryDelayedIn env pat
retryDelayedIn env (TDelayed fc r tm) = retryDelayedIn env tm
retryDelayedIn env (TDelay fc r tm) = retryDelayedIn env tm
retryDelayedIn env (TForce fc tm) = retryDelayedIn env tm
retryDelayedIn env tm = pure ()

