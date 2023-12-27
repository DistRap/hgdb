{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
module Main where

import Prelude hiding (break)

import Data.Bits
import Data.Default.Class
import Data.Word
import Text.Printf

import Control.Concurrent (threadDelay, myThreadId, throwTo, forkIO)
import qualified Control.Exception as E
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.State.Strict
import Control.Monad.Trans.Reader

import System.Console.Repline hiding (options)
import System.Directory

import Gdb
import Data.SVD.Types (Device)
import qualified Data.SVD.IO
import qualified Data.SVD.Pretty.Explore
import qualified Data.SVD.Util

import EmHell.Completion
import Options
import Selector

-- handler
import System.Posix.Signals (Handler(Catch))
import qualified Control.Exception
import qualified System.Posix.Signals

type Repl a = HaskelineT (StateT (Maybe Device) (GDBT IO)) a

main = do
  opts <- runOpts

  let gdbConfig = if optsArm opts then armConfig else def
      cfg = gdbConfig { confLogfile = optsMILog opts }

  case optsCwd opts of
    Nothing -> return ()
    Just pth -> setCurrentDirectory pth -- "/home/srk/git/ivory-tower-helloworld"

  dev <- case optsSVD opts of
    Nothing -> return Nothing
    Just fp -> do
      liftIO $ putStrLn $ "Loading SVD file " ++ fp
      x <- Data.SVD.IO.parseSVD fp
      case x of
        Left err -> putStrLn err >> return Nothing
        Right dev -> return $ Just dev


  runGDBConfig cfg $ do
    maybe (return ()) file (optsFile opts)
    maybe (return ()) extRemote (optsProg opts)
    forM_ (optsEx opts) $ \x -> cli x

    --breakpoint $ C.function_location "callback_extint_handle_4_thread_signal_EXTI15_10_IRQHandler"
    --run
    {--
    forever $ do
      onBreak $ \b -> do
        val <- eval "xcnt_4"
        echo val
    --}
    break

    -- to avoid printing prompt during gdb log output
    liftIO $ threadDelay 1000000
    void $ flip runStateT dev $ runRepl


runRepl :: StateT (Maybe Device) (GDBT IO) ()
runRepl = do
    evalRepl
      banner
      (replCmd)
      options
      (Just ':')
      (Just "paste")
      (Prefix (\x -> (compFunc $ svdCompleterMay) x ) (defaultMatcher))
      greeter
      finalizer
  where
    banner = pure . \case
      SingleLine -> "hgdb> "
      MultiLine -> "| "
    greeter = liftIO $ putStrLn "Welcome to hgdb"
    finalizer = return Exit

replCmd :: String -> Repl ()
replCmd input = lift $ do
  svdMay <- get
  case svdMay of
    Nothing -> lift $ cli input
    Just dev -> do
      case parseSelector input of
        Left _e -> do
          lift $ cli input
        Right sel -> do
          case Data.SVD.Util.getPeriphRegAddr (selPeriph sel) (selReg sel) dev of
            Left e -> lift $ echo e
            Right regAddr -> do
              res <- lift $ readMem regAddr 4
              case res of
                Nothing -> error "Failed to read memory via GDB"
                Just x -> do
                  case
                    Data.SVD.Util.getPeriphReg
                      (selPeriph sel)
                      (selReg sel)
                      dev
                    of
                      Left e -> error "Absurd"
                      Right reg ->
                        liftIO
                          $ Data.SVD.Pretty.Explore.exploreRegister 
                              (x :: Word32)
                              regAddr
                              reg

wait :: String -> Repl ()
wait _args = liftGdb $ waitStop >>= showStops

loadSVD :: String -> Repl ()
loadSVD fp = do
  liftIO $ putStrLn $ "Loading SVD file " ++ fp
  x <- liftIO $ Data.SVD.IO.parseSVD fp
  case x of
    Left err -> liftIO $ putStrLn err
    Right d -> lift $ put $ Just d

-- does make sense only when GDB is running, add continue >> act??
interruptible :: Show b => GDBT IO b -> a -> Repl ()
interruptible act _args = do
  ctx <- liftGdb getContext
  x <- liftIO $ E.try $ sigintHandler $ runGDBT ctx act
  _ <- case x of
    Left e -> do
      -- if user hits Ctr-C we propagate it to GDB and wait for stops response
      liftIO $ print e
      liftIO $ print "sending break"
      liftGdb break
      liftIO $ print "nowait"
      --wait []
      return $ Left $ show (e :: E.SomeException)
    Right r -> return $ Right r

  return ()

defaultMatcher :: [(String, CompletionFunc (StateT (Maybe Device) (GDBT IO)))]
defaultMatcher =
  [ (":svd", fileCompleter)
  , (":file", fileCompleter)
  ]

liftGdb
  :: ( MonadTrans t1
     , MonadTrans t2
     , Monad m
     , Monad (t2 m)
     )
  => m a
  -> t1 (t2 m) a
liftGdb fn = lift . lift $ fn

fileArg fn x = liftGdb $ fn x

options :: [(String, String -> Repl ())]
options = [
    ("svd", loadSVD)
  , ("file", fileArg $ file)
  , ("wait", wait)
  , ("c", interruptible $ continue >> waitStop)
  ]

sigintHandler :: IO b -> IO b
sigintHandler ofWhat = do
    tid <- Control.Concurrent.myThreadId
    Control.Exception.bracket
      (System.Posix.Signals.installHandler
         System.Posix.Signals.sigINT
         (Catch
            $ Control.Exception.throwTo
                tid
                Control.Exception.UserInterrupt
          )
         Nothing
      )
      (\old ->
         System.Posix.Signals.installHandler
           System.Posix.Signals.sigINT
           old
           Nothing
      )
      $ pure ofWhat


