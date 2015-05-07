module Model where

import           Communication
import           Control.Concurrent (forkIO, killThread)
import           Control.Exception (catch, throwIO, SomeException)
import           Control.Monad (forever, when)
import           Data.Aeson (eitherDecodeStrict, encode)
import           Data.ByteString.Lazy (toStrict)
import qualified Data.ByteString.Lazy as BL
import           Data.Function (fix)
import           Data.List (partition)
import           Data.Maybe (isJust)
import qualified Data.Text as T
import           Data.Text.Encoding (encodeUtf8, decodeUtf8)
import           GHCJS.Foreign (toJSString)
import           Import
import           Language.JsonGrammar (Json)
import qualified React.Ace as Ace
import           React.Internal (appState)

getApp :: IO App
getApp = do
  ace <- Ace.getDef
  let state = State
        { _stateAce = ace
        , _stateStatus = Nothing
        , _stateRunning = NotRunning
        , _stateTab = BuildTab
        , _stateInfo = ""
        , _stateConsole = []
        }
  makeApp state id

runApp :: App -> IO void
runApp app = withUrl "ws://localhost:3000/editor" $ \conn' -> do
  let conn = BackendConnection conn'
  version <- receiveResponse conn passthrough _ResponseWelcome
    "handshake response (ResponseWelcome)"
  putStrLn $ "Connection established with ide-backend " ++ show version
  let state = appState app
  files <- waitForTVarIO state (^? (stateStatus . _Just . _BuildRequested))
  mainLoop conn state files `catch` \ex -> do
    consoleError $ toJSString $
      "Exited mainLoop with exception " ++ show (ex :: SomeException)
    throwIO ex

mainLoop :: BackendConnection -> TVar State -> [(FilePath, Text)] -> IO void
mainLoop conn state files = do
  success <- compileCode conn state files
  rh <- if success then runConsole conn state else return ignoreConsoleOutput
  mainLoop conn state =<< runQueries conn state rh

compileCode :: BackendConnection -> TVar State -> [(FilePath, Text)] -> IO Bool
compileCode conn state files = do
  --TODO: clear ide-backend state before the rest of the updates.
  let requestUpdate (fp, txt) = RequestUpdateSourceFile fp $
        BL.fromStrict (encodeUtf8 txt)
  sendRequest conn $ RequestUpdateSession $ map requestUpdate files
  -- Show the build's progress and wait for it to finish.
  fix $ \loop -> do
    mprogress <- receiveResponse conn ignoreConsoleOutput _ResponseUpdateSession
      "compilation progress (ResponseUpdateSession)"
    setTVarIO state stateStatus (Just (Building mprogress))
    when (isJust mprogress) loop
  -- Retrieve the errors
  sourceErrors <- getSourceErrors conn ignoreConsoleOutput
  let partitionKind k = partition ((==k) . errorKind)
  let (errors, partitionKind KindWarning -> (warnings, serverDieds)) =
        partitionKind KindError sourceErrors
  setTVarIO state stateStatus $ Just $ Built $ BuildInfo
    { buildErrors = errors
    , buildWarnings = warnings
    , buildServerDieds = serverDieds
    }
  return (null errors && null serverDieds)

runConsole :: BackendConnection -> TVar State -> IO ResponseHandler
runConsole conn state = do
  switchToConsoleFirstTime <- once $ setTVarIO state stateTab ConsoleTab
  sendRequest conn $ RequestRun "Main" "main"
  return $ \response ->
    case response of
      ResponseProcessOutput output -> do
        switchToConsoleFirstTime
        modifyTVarIO state stateConsole $ (++ [decodeUtf8 output])
        return HandledResponse
      ResponseProcessDone result -> do
        modifyTVarIO state stateConsole $
          (++ ["\nProcess done: ", T.pack (show result)])
        return HandledResponse
      _ -> return Didn'tHandleResponse

-- killRunningProcess :: BackendConnection -> TVar State ->

runQueries :: BackendConnection -> TVar State -> ResponseHandler -> IO [(FilePath, Text)]
runQueries conn state rh = do
  let receiveConsole = forever $
        receiveResponse conn rh (error "expected nothing") "nothing"
      userRequest = waitForTVarIO state $ \s -> case s ^. stateStatus of
        Just (BuildRequested files) -> Just (Left files)
        Just (QueryRequested _ query) -> Just (Right query)
        _ -> Nothing
  -- FIXME: I tried to do this with 'race' initially, but it
  -- erroneously threw thread killed exceptions.  Check if newer GHCJS
  -- resolves this.
  tid <- forkIO receiveConsole
  res <- userRequest
  killThread tid
  case res of
    Left files -> return files
    Right (QueryInfo ss) -> do
      infos <- getSpanInfo conn rh ss
      let backToIdle (Just (QueryRequested info _)) = Just (Built info)
          backToIdle x = x
      modifyTVarIO state id $
        over stateStatus backToIdle .
        set stateInfo (tshow infos)
      runQueries conn state rh

--------------------------------------------------------------------------------
-- Queries

getSourceErrors :: BackendConnection -> ResponseHandler -> IO [SourceError]
getSourceErrors conn rh =
  queryBackend conn rh
               RequestGetSourceErrors
               _ResponseGetSourceErrors
               "ResponseGetSourceErrors"

getSpanInfo :: BackendConnection -> ResponseHandler -> SourceSpan -> IO [ResponseSpanInfo]
getSpanInfo conn rh ss =
  queryBackend conn rh
               (RequestGetSpanInfo ss)
               _ResponseGetSpanInfo
               "ResponseGetSpanInfo"

getExpTypes :: BackendConnection -> ResponseHandler -> SourceSpan -> IO [ResponseExpType]
getExpTypes conn rh ss =
  queryBackend conn rh
               (RequestGetExpTypes ss)
               _ResponseGetExpTypes
               "ResponseGetExpTypes"

queryBackend :: BackendConnection
             -> ResponseHandler
             -> Request
             -> Prism' Response a
             -> String
             -> IO a
queryBackend conn rh request p expected = do
  sendRequest conn request
  receiveResponse conn rh p expected

--------------------------------------------------------------------------------
-- Functions for sending and receiving ide-backend-client requests / responses

newtype BackendConnection =
  BackendConnection { unBackendConnection :: Connection }

sendRequest :: BackendConnection -> Request -> IO ()
sendRequest = sendJson . unBackendConnection

receiveResponse :: BackendConnection
                -> ResponseHandler
                -> Prism' Response a
                -> String
                -> IO a
receiveResponse = receiveJson . unBackendConnection

type ResponseHandler = Response -> IO HandledResponse

--TODO: use actual console warnings
ignoreConsoleOutput :: ResponseHandler
ignoreConsoleOutput (ResponseProcessDone _) = do
  putStrLn "Warning: ignored console output"
  return HandledResponse
ignoreConsoleOutput (ResponseProcessOutput _) = do
  putStrLn "Warning: ignored console output"
  return HandledResponse
ignoreConsoleOutput _ = return Didn'tHandleResponse

--------------------------------------------------------------------------------
-- Functions for sending and receiving JSON

sendJson :: Json a => Connection -> a -> IO ()
sendJson conn req =
  sendText conn (decodeUtf8 (toStrict (encode (toJSON req))))

data HandledResponse
    = HandledResponse
    | Didn'tHandleResponse
    deriving (Eq)

passthrough :: a -> IO HandledResponse
passthrough _ = return Didn'tHandleResponse

receiveJson :: (Json r, Show r)
            => Connection
            -> (r -> IO HandledResponse)
            -> Prism' r a
            -> String
            -> IO a
receiveJson conn rh p expected = do
  t <- receiveText conn
  case eitherDecodeStrict (encodeUtf8 t) of
    Left err -> fail $ "Protocol error: " ++ err
    Right val ->
      case fromJSON val of
        Left err -> fail $ "Protocol error: " ++ err
        Right response -> do
          handled <- rh response
          case handled of
            HandledResponse -> receiveJson conn rh p expected
            Didn'tHandleResponse ->
              case response ^? p of
                Just x -> return x
                Nothing ->
                  fail $
                    "Protocol error, expected " ++ expected ++
                    ", but got " ++ show response

--------------------------------------------------------------------------------
-- Mutation functions invoked by View

runCode :: TVar State -> [(FilePath, Text)] -> IO ()
runCode state files =
  modifyTVarIO state stateStatus $ \oldStatus ->
    case oldStatus of
      Just (Building _) -> oldStatus
      _ -> Just $ BuildRequested files

runQuery :: TVar State -> Query -> IO ()
runQuery state query =
  modifyTVarIO state stateStatus $ \oldStatus ->
    case oldStatus of
      Just (Built info) -> Just $ QueryRequested info query
      _ -> oldStatus

switchTab :: TVar State -> Tab -> IO ()
switchTab state tab =
  setTVarIO state stateTab tab
