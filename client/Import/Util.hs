module Import.Util where

import           Control.Concurrent.STM
import           Control.Exception (SomeException, catch, throwIO)
import           Control.Lens
import           Control.Monad (unless)
import           Control.Monad.Trans.Maybe (MaybeT(..))
import           Data.Char (isHexDigit)
import           Data.IORef
import           Data.Monoid
import           Data.Text (Text, pack)
import qualified Data.Text as T
import           GHCJS.Foreign
import           GHCJS.Marshal
import           GHCJS.Types
import           IdeSession.Client.JsonAPI
import           IdeSession.Types.Public
import           React

addWhen :: Bool -> Text -> Text -> Text
addWhen True x y = y <> " " <> x
addWhen False _ y = y

tshow :: Show a => a -> Text
tshow = pack . show

once :: IO () -> IO (IO ())
once runAction = do
  alreadyCalledRef <- newIORef False
  return $ do
    alreadyCalled <- readIORef alreadyCalledRef
    unless alreadyCalled runAction

--------------------------------------------------------------------------------
-- Misc React utils

prop :: FromJSRef a => JSRef obj -> JSString -> IO (Maybe a)
prop obj n = do
  ref <- getProp n obj
  if isUndefined ref || isNull ref
    then return Nothing
    else fromJSRef ref

mtprop :: FromJSRef a => JSRef obj -> JSString -> MaybeT IO a
mtprop obj n = MaybeT $ prop obj n

expectProp :: FromJSRef a => JSRef obj -> JSString -> IO a
expectProp obj n = do
  mx <- prop obj n
  case mx of
    Nothing -> fail $ "Couldn't find expected property " ++ fromJSString n
    Just x -> return x

setPropShow :: (Monad m, Show a) => T.Text -> a -> ReactT state m ()
setPropShow n = attr n . T.pack . show

--------------------------------------------------------------------------------
-- Tvar/lens helpers

setTVarIO :: TVar s -> ASetter' s a -> a -> IO ()
setTVarIO v l a =
  atomically
    (modifyTVar v
                (set l a))

modifyTVarIO :: TVar s -> ASetter' s a -> (a -> a) -> IO ()
modifyTVarIO v l f =
  atomically
    (modifyTVar v
                (over l f))

waitForTVarIO :: TVar s -> (s -> Maybe a) -> IO a
waitForTVarIO v f = atomically $ do
  x <- readTVar v
  case f x of
    Just y -> return y
    Nothing -> retry

viewTVarIO ::  TVar s -> Getting a s a -> IO a
viewTVarIO v g =
  atomically
    (fmap (view g)
          (readTVar v))

foreign import javascript "console.log($1)" consoleLog :: JSRef a -> IO ()

foreign import javascript "console.warn($1)" consoleWarn :: JSRef a -> IO ()

foreign import javascript "console.error($1)" consoleError :: JSRef a -> IO ()

showExceptions :: Text -> IO a -> IO a
showExceptions msg f = f `catch` \ex -> do
  consoleError $ toJSString ("Exception in " <> msg <> ": " <> tshow (ex :: SomeException))
  throwIO ex

showAndIgnoreExceptions :: Text -> IO () -> IO ()
showAndIgnoreExceptions msg f = f `catch` \ex ->
  consoleError $ toJSString ("Exception ignored in " <> msg <> ": " <> tshow (ex :: SomeException))

--------------------------------------------------------------------------------
-- JsonAPI helpers

displayIdInfo :: IdInfo -> Text
displayIdInfo (IdInfo IdProp {..} scope) =
    "'" <> idName <> "' " <> displayNameSpace idSpace <> " " <>
    case scope of
      Binder -> "binding"
      Local -> "defined locally" <>
        case idDefSpan of
          ProperSpan ss -> ", at " <> tshow ss
          _ -> ""
      Imported {..} ->
        "imported from " <> displayModuleId idImportedFrom <>
        (if idDefinedIn /= idImportedFrom
          then ", and defined in " <> displayModuleId idDefinedIn
          else "")
      WiredIn -> "builtin defined in " <> displayModuleId idDefinedIn

displayNameSpace :: IdNameSpace -> Text
displayNameSpace VarName = "value"
displayNameSpace DataName = "data constructor"
displayNameSpace TvName = "type variable"
displayNameSpace TcClsName = "type"

displayModuleId :: ModuleId -> Text
displayModuleId (ModuleId mo pkg) = mo <> " (" <> displayPackageId pkg <> ")"

displayPackageId :: PackageId -> Text
displayPackageId (PackageId name (Just version) _pkey) =
  name <> "-" <> cleanPackageVersion version
displayPackageId (PackageId name Nothing _pkey) =
  name

-- | In our environment, ghc-prim / base / etc has a name like this
--
-- ghc-prim-0.3.1.0-3f9f683cd77bf581e40e5d3162876874
--
-- It seems like a good hack for now to just strip the "-hash" off any
-- such package versions.  Consider moving it to ide-backend-client?
cleanPackageVersion :: Text -> Text
cleanPackageVersion x@(T.stripPrefix "-" . T.takeEnd 33 -> Just hash)
  | T.all isHexDigit hash = T.dropEnd 33 x
cleanPackageVersion x = x

$(makePrisms ''Response)
