module Import
    ( module Control.Applicative
    , module Control.Concurrent.STM
    , module Control.Lens
    , module Control.Monad
    , module Data.Foldable
    , module Data.Maybe
    , module Data.Monoid
    , module Data.Traversable
    , module GHCJS.Foreign
    , module GHCJS.Marshal
    , module GHCJS.Types
    , module IdeSession.Types.Progress
    , module IdeSession.Types.Public
    , module Import.Util
    , module JavaScript.Unmanaged
    , module Prelude
    , module React
    , module React.Lucid
    , module Stack.Ide.JsonAPI
    , module Types
    , ByteString
    , Text
    -- * Simplified types
    , React
    , App
    , Component
    , UComponent
    -- * Misc utils
    , ixSnippet
    , getEditor
    , readEditor
    , currentSnippet
    , positionControlsOnResize
    , schedulerHost
    , noDocsUrl
    ) where

import           Control.Applicative ((<$>), (<*>))
import           Control.Concurrent.STM
import           Control.Lens hiding (Sequenced)
import           Control.Monad (void, join, when, unless, forever, (>=>), (<=<))
import           Data.ByteString (ByteString)
import           Data.Foldable (forM_, mapM_)
import           Data.Maybe
import           Data.Monoid
import           Data.Text (Text)
import           Data.Traversable (forM, mapM)
import           GHCJS.Foreign
import           GHCJS.Marshal
import           GHCJS.Types
import           IdeSession.Types.Progress
import           IdeSession.Types.Public
import           Import.Util
import           JavaScript.Ace (Editor)
import           JavaScript.Unmanaged
import           Prelude hiding (mapM, mapM_)
import           React hiding (App, getElementById)
import qualified React.Internal
import           React.Lucid
import           Stack.Ide.JsonAPI
import           Types

type React a = ReactT State IO a

type App = React.Internal.App State IO

type Component a = React.Internal.Component State a IO

type UComponent a = React.Internal.Component State (Unmanaged a) IO

ixSnippet :: SnippetId -> Traversal' State Snippet
ixSnippet (SnippetId sid) = stateSnippets . ix sid

getEditor :: State -> SnippetId -> IO Editor
getEditor state sid =
  getUnmanagedOrFail (state ^? ixSnippet sid . snippetEditor)

readEditor :: TVar State -> SnippetId -> IO Editor
readEditor stateVar sid =
  readUnmanagedOrFail stateVar (^? ixSnippet sid . snippetEditor)

currentSnippet :: State -> Maybe SnippetId
currentSnippet state =
  case state ^. stateStatus of
    InitialStatus -> Nothing
    BuildRequested (BuildRequest sid _) -> Just sid
    Building sid _ -> Just sid
    Built sid _ -> Just sid
    QueryRequested sid _ _ -> Just sid
    KillRequested sid _ -> Just sid

foreign import javascript unsafe
  "positionControlsOnResize"
  positionControlsOnResize :: Element -> Element -> IO ()

schedulerHost :: Text
#if LOCAL_SOH_SCHEDULER
schedulerHost = "http://localhost:3000"
#else
schedulerHost = "http://soh-scheduler-1627848338.us-east-1.elb.amazonaws.com"
#endif

noDocsUrl :: Text
--FIXME
-- noDocsUrl = schedulerHost <> "/static/no-docs-available.html"
noDocsUrl = "no-docs-available.html"
