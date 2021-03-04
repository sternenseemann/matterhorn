{-# LANGUAGE LambdaCase #-}
module Matterhorn.State.Attachments
  ( showAttachmentList
  , resetAttachmentList
  , showAttachmentFileBrowser
  , attachFileByPath
  , tryAddAttachment
  , tryReadAttachment
  )
where

import           Prelude ()
import           Matterhorn.Prelude

import           Brick ( vScrollToBeginning, viewportScroll )
import qualified Brick.Widgets.List as L
import qualified Brick.Widgets.FileBrowser as FB
import qualified Control.Exception as E
import qualified Control.Monad.State as St
import           Data.Bool ( bool )
import qualified Data.ByteString as BS
import           Data.Either ( isRight )
import           Data.Text ( pack, unpack )
import qualified Data.Vector as Vector
import           Lens.Micro.Platform ( (.=), (%=) )
import           System.Directory ( doesDirectoryExist, getDirectoryContents )

import           Matterhorn.Types

validateAttachmentPath :: FilePath -> IO (Maybe FilePath)
validateAttachmentPath path = bool Nothing (Just path) <$> do
    ex <- doesDirectoryExist path
    case ex of
        False -> return False
        True -> do
            result :: Either E.SomeException [FilePath]
                   <- E.try $ getDirectoryContents path
            return $ isRight result

defaultAttachmentsPath :: Config -> IO (Maybe FilePath)
defaultAttachmentsPath = maybe (return Nothing) validateAttachmentPath . configDefaultAttachmentPath

showAttachmentList :: MH ()
showAttachmentList = do
    lst <- use (csCurrentTeam.tsEditState.cedAttachmentList)
    case length (L.listElements lst) of
        0 -> showAttachmentFileBrowser
        _ -> setMode ManageAttachments

resetAttachmentList :: MH ()
resetAttachmentList = do
    tId <- use csCurrentTeamId
    let listName = AttachmentList tId
    csCurrentTeam.tsEditState.cedAttachmentList .= L.list listName mempty 1
    mh $ vScrollToBeginning $ viewportScroll listName

showAttachmentFileBrowser :: MH ()
showAttachmentFileBrowser = do
    config <- use (csResources.crConfiguration)
    tId <- use csCurrentTeamId
    filePath <- liftIO $ defaultAttachmentsPath config
    browser <- liftIO $ Just <$> FB.newFileBrowser FB.selectNonDirectories (AttachmentFileBrowser tId) filePath
    csCurrentTeam.tsEditState.cedFileBrowser .= browser
    setMode ManageAttachmentsBrowseFiles

attachFileByPath :: Text -> MH ()
attachFileByPath txtPath = do
    let strPath = unpack txtPath
    fileInfo <- liftIO $ FB.getFileInfo strPath strPath
    case FB.fileInfoFileStatus fileInfo of
        Left _ -> do
            mhLog LogError $ "Failed to obtain FileInfo for file: " <> txtPath
            mhError $ BadFile txtPath
        Right _ -> tryAddAttachment [fileInfo]

tryAddAttachment :: [FB.FileInfo] -> MH ()
tryAddAttachment entries = do
    forM_ entries $ \entry -> do
        -- Is the entry already present? If so, ignore the selection.
        es <- use (csCurrentTeam.tsEditState.cedAttachmentList.L.listElementsL)
        let matches = (== FB.fileInfoFilePath entry) .
                          FB.fileInfoFilePath .
                          attachmentDataFileInfo
        case Vector.find matches es of
            Just _ -> return ()
            Nothing -> do
                tryReadAttachment entry >>= \case
                    Right a -> do
                        oldIdx <- use (csCurrentTeam.tsEditState.cedAttachmentList.L.listSelectedL)
                        let newIdx = if Vector.null es
                                     then Just 0
                                     else oldIdx
                        csCurrentTeam.tsEditState.cedAttachmentList %= L.listReplace (Vector.snoc es a) newIdx
                    Left (_::E.SomeException) -> do
                        mhLog LogError $ pack $ "Failed reading file: " <> FB.fileInfoFilePath entry
                        mhError $ BadFile $ pack $ FB.fileInfoFilePath entry

    when (not $ null entries) $ setMode Main

tryReadAttachment :: FB.FileInfo -> MH (Either E.SomeException AttachmentData)
tryReadAttachment fi = do
    let path = FB.fileInfoFilePath fi
    mhLog LogError "Reading the bytes"
    readResult <- liftIO $ E.try $ BS.readFile path
    case readResult of
        Right bytes -> do
            return $ Right $
                AttachmentData { attachmentDataFileInfo = fi
                               , attachmentDataBytes = bytes
                               }
        Left e -> return $ Left e
