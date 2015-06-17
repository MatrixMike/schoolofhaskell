module Import
    ( module Control.Applicative
    , module Control.Concurrent.STM
    , module Control.Lens
    , module Control.Monad
    , module Data.Foldable
    , module Data.Maybe
    , module Data.Monoid
    , module Data.Traversable
    , module IdeSession.Client.JsonAPI
    , module IdeSession.Types.Progress
    , module IdeSession.Types.Public
    , module Import.Util
    , module React
    , module React.Lucid
    , module React.Unmanaged
    , module Types
    , module GHCJS.Foreign
    , module GHCJS.Marshal
    , module GHCJS.Types
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
    ) where

import           Ace (Editor)
import           Control.Applicative ((<$>), (<*>))
import           Control.Concurrent.STM
import           Control.Lens
import           Control.Monad (void, join, when, unless, forever, (>=>), (<=<))
import           Data.ByteString (ByteString)
import           Data.Foldable (forM_)
import           Data.Maybe
import           Data.Monoid
import           Data.Text (Text)
import           Data.Traversable (forM)
import           GHCJS.Foreign
import           GHCJS.Marshal
import           GHCJS.Types
import           IdeSession.Client.JsonAPI
import           IdeSession.Types.Progress
import           IdeSession.Types.Public
import           Import.Util
import           React hiding (App)
import qualified React.Internal
import           React.Lucid
import           React.Unmanaged
import           Types

type React a = ReactT State IO a

type App = React.Internal.App State IO

type Component a = React.Internal.Component State a IO

type UComponent a = React.Internal.Component State (Unmanaged a) IO

-- TODO: move these to a utilities module?

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
