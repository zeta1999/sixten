{-# LANGUAGE FlexibleContexts, OverloadedStrings #-}
module Command.Check where

import Data.Monoid
import qualified Data.Text.IO as Text
import Options.Applicative
import System.IO
import Util

import qualified Backend.Target as Target
import Command.Check.Options
import qualified Processor.Files as Processor
import qualified Processor.Result as Processor

optionsParserInfo :: ParserInfo Options
optionsParserInfo = info (helper <*> optionsParser)
  $ fullDesc
  <> progDesc "Type check a Sixten program"
  <> header "sixten check"

optionsParser :: Parser Options
optionsParser = Options
  <$> nonEmptySome (strArgument
    $ metavar "FILES..."
    <> help "Input source FILES"
    <> action "file"
    )
  <*> option auto
    (long "verbose"
    <> short 'v'
    <> metavar "LEVEL"
    <> help "Set the verbosity level to LEVEL"
    <> value 0
    <> completeWith ["0", "10", "20", "30", "40"]
    )
  <*> optional (strOption
    $ long "log-file"
    <> metavar "FILE"
    <> help "Write logs to FILE instead of standard output"
    <> action "file"
    )

check
  :: Options
  -> IO ()
check opts = withLogHandle (logFile opts) $ \logHandle -> do
  procResult <- Processor.checkFiles Processor.Arguments
        { Processor.sourceFiles = inputFiles opts
        , Processor.assemblyDir = ""
        , Processor.target = Target.defaultTarget
        , Processor.logHandle = logHandle
        , Processor.verbosity = verbosity opts
        , Processor.silentErrors = False
        }
  case procResult of
    Processor.Failure _ -> Text.putStrLn "Type checking failed"
    Processor.Success [] -> Text.putStrLn "Type checking completed successfully"
    Processor.Success (_:_) -> Text.putStrLn "Type checking failed"
  where
    withLogHandle Nothing k = k stdout
    withLogHandle (Just file) k = Util.withFile file WriteMode k

command :: ParserInfo (IO ())
command = check <$> optionsParserInfo
