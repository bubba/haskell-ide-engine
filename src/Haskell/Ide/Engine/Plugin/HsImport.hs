{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module Haskell.Ide.Engine.Plugin.HsImport where

import           Control.Monad.IO.Class
import           Data.Aeson
import qualified Data.Text                     as T
import qualified Data.Text.IO                  as T
import qualified GHC.Generics                  as Generics
import qualified GhcMod.Utils                  as GM
import           HsImport
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.MonadTypes
import qualified Language.Haskell.LSP.Types    as J
import           Haskell.Ide.Engine.PluginUtils
import           System.Directory
import           System.IO

hsimportDescriptor :: PluginDescriptor
hsimportDescriptor = PluginDescriptor
  { pluginName = "hsimport"
  , pluginDesc = "A tool for extending the import list of a Haskell source file."
  , pluginCommands = [PluginCommand "import" "Import a module" importCmd]
  }

data ImportParams = ImportParams Uri T.Text
  deriving (Show, Eq, Generics.Generic, ToJSON, FromJSON)

importCmd :: CommandFunc ImportParams J.WorkspaceEdit
importCmd = CmdSync $ \(ImportParams uri modName) -> importModule uri modName

importModule :: Uri -> T.Text -> IdeGhcM (IdeResult J.WorkspaceEdit)
importModule uri modName =
  pluginGetFile "hsimport cmd: " uri $ \origInput -> do
    logm "inside import"
    fileMap <- GM.mkRevRedirMapFunc
    GM.withMappedFile origInput $ \input -> liftIO $ do

      tmpDir            <- getTemporaryDirectory
      (output, outputH) <- openTempFile tmpDir "hsimportOutput"
      hClose outputH

      let args = defaultArgs { moduleName    = T.unpack modName
                             , inputSrcFile  = input
                             , outputSrcFile = output
                             }
      maybeErr <- liftIO $ hsimportWithArgs defaultConfig args
      logm $ show maybeErr
      case maybeErr of
        Just err -> do
          removeFile output
          let msg = T.pack $ show err
          return $ IdeResultFail (IdeError PluginError msg Null)
        Nothing -> do
          newText <- T.readFile output
          logm "did this part"
          removeFile output
          logm "removed file"
          workspaceEdit <- makeDiffResult input newText fileMap
          logm "made diff result"
          return $ IdeResultOk workspaceEdit