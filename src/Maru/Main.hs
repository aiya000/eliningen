-- Suppress warnings what is happend by TemplateHaskell
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE UndecidableInstances #-}

module Maru.Main
  ( runRepl
  ) where

import Control.Eff (Eff, Member, SetMember, (:>))
import Control.Eff.Exception (throwExc, Fail, runFail)
import Control.Eff.Lift (Lift, lift, runLift)
import Control.Eff.State.Lazy (State, runState)
import Control.Exception.Safe (SomeException)
import Control.Monad (mapM, when, void, forM_)
import Control.Monad.Fail (MonadFail(..))
import Control.Monad.State.Class (MonadState(..), gets)
import Data.Data (Data)
import Data.Function ((&))
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Typeable (Typeable)
import Data.Types.Injective (Injective(..))
import Data.Void (Void)
import Language.Haskell.TH (Name, mkName, nameBase, DecsQ)
import Lens.Micro ((.~))
import Lens.Micro.Mtl ((.=), (%=))
import Lens.Micro.TH (DefName(..), lensField, makeLensesFor, makeLensesWith, lensRules)
import Maru.Type (SExpr, ParseErrorResult, MaruEnv, SimplificationSteps, reportSteps, liftMaybeM)
import System.Console.CmdArgs (cmdArgs, summary, program, help, name, explicit, (&=))
import TextShow (showt)
import qualified Control.Eff.State.Lazy as EST
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Maru.Eval as Eval
import qualified Maru.Parser as Parser
import qualified Maru.Type as MT
import qualified System.Console.Readline as R

-- | Command line options
data CliOptions = CliOptions
  { debugMode :: Bool
  , doEval    :: Bool
  } deriving (Show, Data, Typeable)

--TODO: Use makeLensesA after GHC is fixed (https://ghc.haskell.org/trac/ghc/ticket/13932)
makeLensesFor [ ("debugMode", "debugModeA")
              , ("doEval", "doEvalA")
              ] ''CliOptions
--makeLensesA ''CliOptions

-- | Default of @CliOptions@
cliOptions :: CliOptions
cliOptions = CliOptions
  { debugMode = False &= name "debug"
  , doEval    = True &= name "do-eval"
                     &= help "If you don't want to evaluation, disable this"
                     &= explicit
  }
  &= summary "マルのLisp処理系ずら〜〜"
  &= program "maru"


-- |
-- Logs of REPL.
--
-- This is collected in 'Read' and 'Eval' phase of REPL,
-- and this is shown in 'Print' phase of REPL.
--
-- This is not shown if you doesn't specifiy --debug.
data DebugLogs = DebugLogs
  { readLogs :: [Text]
  , evalLogs :: [Text]
  } deriving (Show)

makeLensesFor [ ("readLogs", "readLogsA")
              , ("evalLogs", "evalLogsA")
              ] ''DebugLogs
--makeLensesA ''DebugLogs

emptyDebugLog :: DebugLogs
emptyDebugLog = DebugLogs [] []


-- | Integrate any type as @State@ of REPL.
data ReplState = ReplState
  { replOpts :: CliOptions -- ^ specified CLI options (not an initial value)
  , replEnv  :: MaruEnv    -- ^ The symbols of zuramaru
  , replLogs :: DebugLogs  -- ^ this value is appended in the runtime
  }

makeLensesFor [ ("replOpts", "replOptsA")
              , ("replEnv", "replEnvA")
              , ("replLogs", "replLogsA")
              ] ''ReplState
--makeLensesA ''ReplState


-- | For Lens Accessors
instance Member (State ReplState) r => MonadState ReplState (Eff r) where
  get = EST.get
  put = EST.put


-- |
-- The locally @MonadFail@ context
-- (This overrides existed @MonadFail@ instance)
instance Member Fail r => MonadFail (Eff r) where
  fail _ = throwExc ()


instance Injective (Maybe ()) Bool where
  to (Just ()) = True
  to Nothing   = False



-- |
-- The eval phase do parse and evaluation,
-- take its error or a rightly result
data EvalPhaseResult = ParseError ParseErrorResult -- ^ An error is happened in the parse
                     | EvalError SomeException     -- ^ An error is happend in the evaluation
                     | RightResult SExpr           -- ^ A result is made by the parse and the evaulation without errors

type Evaluator = MaruEnv -> SExpr -> IO (Either SomeException (SExpr, MaruEnv, SimplificationSteps))


-- | Run REPL of zuramaru
runRepl :: IO ()
runRepl = do
  options <- cmdArgs cliOptions
  let initialState = ReplState options Eval.initialEnv emptyDebugLog
  void . runLift $ runState initialState repl

--TODO: Use polymorphic type "(Member (State ReplState) r, SetMember Lift (Lift IO) r) => Eff r ()"
-- |
-- Do 'Loop' of 'Read', 'eval', and 'Print',
-- with the startup options.
--
-- If some command line arguments are given, enable debug mode.
-- Debug mode shows the parse and the evaluation's optionally result.
repl :: Eff (State ReplState :> Lift IO :> Void) ()
repl = do
  loopIsRequired <- to <$> runFail (rep :: Eff (Fail :> State ReplState :> Lift IO :> Void) ())
  when loopIsRequired repl

-- |
-- Do 'Read', 'Eval', and 'Print' of 'REPL'.
-- Return False if Ctrl+d is input.
-- Return True otherwise.
--
-- If @rep@ throws a () of the error, it means what the loop of REP exiting is required.
rep :: (Member Fail r, Member (State ReplState) r, SetMember Lift (Lift IO) r)
    => Eff r ()
rep = do
  input      <- liftMaybeM readPhase
  evalResult <- evalPhase input
  printPhase evalResult


-- |
-- Read line from stdin.
-- If stdin gives to interrupt, return Nothing.
-- If it's not, return it and it is added to history file
readPhase :: IO (Maybe Text)
readPhase = do
  maybeInput <- R.readline "zuramaru> "
  mapM R.addHistory maybeInput
  return (T.pack <$> maybeInput)

-- |
-- Do parse and evaluate a Text to a SExpr.
-- Return @SExpr@ (maru's AST) if both parse and evaluation is succeed.
-- Otherwise, return a error result.
--
-- Execute the evaluation.
-- A state of @DebugLogs@ is updated by got logs which can be gotten in the evaluation.
-- A state of @MaruEnv@ is updated by new environment of the result.
evalPhase :: (Member (State ReplState) r, SetMember Lift (Lift IO) r)
          => Text -> Eff r EvalPhaseResult
evalPhase code = do
  evalIsNeeded <- gets $ doEval . replOpts
  -- Get a real evaluator or an empty evaluator.
  -- The empty evaluator doesn't touch any arguments.
  let eval' = if evalIsNeeded then Eval.eval
                              else fakeEval
  case Parser.debugParse code of
    (Left parseErrorResult, _) -> return $ ParseError parseErrorResult
    (Right sexpr, logs) -> do
      let (messages, item) = Parser.prettyShowLogs logs
      replLogsA . evalLogsA %= (++ messages ++ [item, "parse result: " <> showt sexpr]) --TODO: Replace to low order algorithm
      env        <- gets replEnv
      evalResult <- lift $ eval' env sexpr
      case evalResult of
        Left evalErrorResult -> return $ EvalError evalErrorResult
        Right (result, newEnv, steps) -> do
          replEnvA .= newEnv
          replLogsA . evalLogsA %= (++ reportSteps steps)
          return $ RightResult result
  where
    -- Do nothing
    fakeEval :: Evaluator
    fakeEval = (return .) . (Right .) . flip (,,[])


-- | Do 'Print' for a result of 'Read' and 'Eval'
printPhase :: (Member (State ReplState) r, SetMember Lift (Lift IO) r)
           => EvalPhaseResult -> Eff r ()
printPhase result = do
  DebugLogs readLogs' evalLogs' <- gets replLogs
  debugMode'                    <- gets $ debugMode . replOpts
  lift $ case result of
    ParseError e      -> TIO.putStrLn . T.pack $ Parser.parseErrorPretty e --TODO: Optimize error column and representation
    EvalError  e      -> TIO.putStrLn . T.pack $ show e
    RightResult sexpr -> TIO.putStrLn $ MT.visualize sexpr
  lift . when debugMode' $ do
    forM_ readLogs' $ TIO.putStrLn . ("<debug>(readPhase): " <>)
    forM_ evalLogs' $ TIO.putStrLn . ("<debug>(evalPhase): " <>)


-- |
-- makeLenses with 'A' suffix.
-- e.g. replEnv -> replEnvA
makeLensesA :: Name -> DecsQ
makeLensesA = makeLensesWith (lensRules & lensField .~ addSuffix)
  where
    addSuffix :: Name -> [Name] -> Name -> [DefName]
    addSuffix _ _ recordName = [TopName . mkName $ nameBase recordName ++ "A"]
