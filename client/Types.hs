module Types where

import Ace (Editor, Range)
import Control.Concurrent.STM (TChan)
import Control.Lens (makeLenses, makePrisms)
import Data.ByteString (ByteString)
import Data.IORef (IORef)
import Data.Text (Text)
import IdeSession.Client.JsonAPI
import IdeSession.Types.Progress
import IdeSession.Types.Public
import React.Unmanaged (Unmanaged)
import TermJs (TermJs)
import React.IFrame

data State = State
  { _stateAce :: !(Unmanaged Editor)
  , _stateConsole :: !(Unmanaged TermJs)
  , _stateWeb :: !(Unmanaged IFrame)
  , _statePosMap :: !PosMap
  , _stateStatus :: !(Maybe Status)
  , _stateRunning :: !Running
  , _stateTab :: !Tab
  , _stateDocs :: !(Maybe IdInfo)
  , _stateTypes :: !(Maybe [ResponseAnnExpType])
  , _stateBackend :: !(Maybe Backend)
  } deriving (Eq, Show, Typeable)

data Status
  = BuildRequested !Files
  | Building !(Maybe Progress)
  | Built !BuildInfo
  | QueryRequested !BuildInfo !Query
  deriving (Eq, Show, Typeable)

data BuildInfo = BuildInfo
  { buildErrors :: ![AnnSourceError]
  , buildWarnings :: ![AnnSourceError]
  , buildServerDieds :: ![AnnSourceError]
  }
  deriving (Eq, Show, Typeable)

data Query
  = QueryInfo !SourceSpan
  deriving (Eq, Show, Typeable)

data Running
  = NotRunning
  | Running
  deriving (Eq, Show, Typeable)

data Tab
  = BuildTab
  | ConsoleTab
  | DocsTab
  | WebTab
  deriving (Eq, Show, Typeable)

type Files = [(FilePath, Text)]

data Backend = Backend
  { backendRequestChan :: TChan Request
  , backendResponseChan :: TChan Response
  , backendProcessHandler :: IORef (Either RunResult ByteString -> IO ())
  } deriving (Typeable)

instance Eq Backend where
  _ == _ = True

instance Show Backend where
  showsPrec _ _ = showString "Backend conn waiter"

-- Note: Newer changes are towards the front of the list.
type PosMap = [PosChange]

data PosChange = PosChange
  { oldRange :: !Range
  , newRange :: !Range
  }
  deriving (Eq, Show, Typeable)

$(makeLenses ''State)
$(makePrisms ''Status)
