-- | Bindings to the Ace editor.
module JavaScript.Ace
  ( Editor
    -- * Construction
  , makeEditor
    -- * Queries
  , getValue
  , getSelection
  , getCharPosition
    -- * Mutations
  , setValue
  , setSelection
  , Editor.focus
  , Editor.blur
  , setMaxLinesInfty
  , MarkerId(..)
  , addMarker
  , removeMarker
    -- * Events
  , onChange
  , ChangeEvent(..)
  , onSelectionChange
  , addCommand
    -- * Auxiliary Types
  , Pos(..)
  , Range(..)
  , Selection(..)
  , selectionToRange
  , rangeToSelection
  , RangeOrdering(..)
  , compareRange
  , comparePosWithRange
  , DeltaPos(..)
  , subtractPos
  , shiftPos
  , shiftRange
  ) where

import           Control.Monad (void, join, (<=<))
import           Control.Monad.Trans.Maybe (MaybeT(..))
import           Data.Coerce (coerce)
import           Data.Text (Text)
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           GHCJS.DOM.Types (HTMLElement(..))
import           GHCJS.Foreign
import           GHCJS.Marshal
import           GHCJS.Types
import           Import.Util (getElement, intToJSNumber, mtprop, fromJSRefOrFail, fromJSRefOrFail')
import qualified JavaScript.AceAjax.Raw.Ace as Ace
import qualified JavaScript.AceAjax.Raw.Editor as Editor
import qualified JavaScript.AceAjax.Raw.IEditSession as Session
import qualified JavaScript.AceAjax.Raw.Selection as Selection
import           JavaScript.AceAjax.Raw.Types hiding (Selection, Range)
import qualified JavaScript.AceAjax.Raw.VirtualRenderer as Renderer
import           JavaScript.JQuery (JQuery)
import           Prelude

--------------------------------------------------------------------------------
-- Construction

makeEditor :: JQuery -> IO Editor
makeEditor q = do
  e <- join $ Ace.edit1 <$> ace <*> getElement 0 q
  Editor.setHighlightActiveLine e (toJSBool False)
  s <- Editor.session e
  Session.setUseWorker s (toJSBool False)
  Session.setMode s "ace/mode/haskell"
  r <- Editor.renderer e
  Renderer.setTheme r "ace/theme/tomorrow"
  Renderer.setShowGutter r (toJSBool False)
  Renderer.setShowPrintMargin r (toJSBool False)
  setGlobalEditor e
  return e

-- Purely for development purposes
foreign import javascript unsafe "window.ace_editor = $1;"
  setGlobalEditor :: Editor -> IO ()

--------------------------------------------------------------------------------
-- Queries

getValue :: Editor -> IO Text
getValue = fmap fromJSString . Editor.getValue

getSelection :: Editor -> IO Selection
getSelection editor = do
  s <- Editor.getSelection editor
  let fromRef = fromJSRefOrFail' "ace editor selection" . coerce
  lead <- Selection.getSelectionLead s
  anchor <- Selection.getSelectionAnchor s
  Selection <$> fromRef lead <*> fromRef anchor

getCharPosition :: Editor -> Pos -> IO (Int, Int)
getCharPosition editor pos = do
  renderer <- Editor.renderer editor
  obj <- Renderer.textToScreenCoordinates
      renderer
      (intToJSNumber (row pos))
      (intToJSNumber (column pos))
  (cx, cy) <- convertPagePosition obj
  (ex, ey) <-
    convertPagePosition =<<
    getPagePosition . coerce =<<
    Renderer.scroller renderer
  print (cx, cy, ex, ey)
  return (cx - ex, cy - ey)

convertPagePosition :: JSRef obj -> IO (Int, Int)
convertPagePosition obj =
  maybe (fail "Failed to convert page position") return =<<
  runMaybeT ((,) <$> mtprop obj "pageX" <*> mtprop obj "pageY")

--FIXME: switch to using GHCJS.DOM.ClientRect once we update to a sufficient version
--
-- foreign import unsafe "$1.getBoundingClientRect()"
--   getBoundingClientRect :: Element -> IO ClientRect

foreign import javascript unsafe
  "function(el) {\
     var rect = el.getBoundingClientRect();\
     return { pageX: rect.left, pageY: rect.top };\
  }($1)"
  getPagePosition :: HTMLElement -> IO (JSRef obj)

--------------------------------------------------------------------------------
-- Mutations

-- Note: -1 specifies that the cursor should be moved to the end
--
setValue :: Editor -> JSString -> IO ()
setValue e val = void $ Editor.setValue e val (intToJSNumber (-1))

setSelection :: Editor -> Selection -> IO ()
setSelection editor Selection{..} = do
  s <- Editor.getSelection editor
  Selection.setSelectionAnchor s
    (intToJSNumber (row anchor))
    (intToJSNumber (column anchor))
  Selection.selectTo s
    (intToJSNumber (row lead))
    (intToJSNumber (column lead))

newtype MarkerId = MarkerId Int
  deriving (Eq, Show)

addMarker :: Editor -> Range -> JSString -> JSString -> Bool -> IO MarkerId
addMarker editor range clazz typ inFront = do
  s <- Editor.session editor
  rangeRef <- toJSRef range
  inFrontRef <- toJSRef inFront
  MarkerId <$> js_addMarker s rangeRef clazz typ inFrontRef

removeMarker :: Editor -> MarkerId -> IO ()
removeMarker editor (MarkerId mid) = do
  s <- Editor.session editor
  js_removeMarker s mid

--------------------------------------------------------------------------------
-- Event Handlers

onChange :: Editor -> (ChangeEvent -> IO ()) -> IO ()
onChange e f = do
  -- TODO: open pull request on ace typescript bindings making things subtypes of EventEmitter?
  parent <- toJSRef =<< Editor.container e
  f' <- syncCallback1 (DomRetain (coerce parent)) True (f <=< fromJSRefOrFail)
  editorOn e "change" f'

--TODO: would be cheaper to not marshal the lines and instead get
--their length (at least for our purposes in this project).

data ChangeEvent
  = InsertLines Range [JSString]
  | InsertText  Range JSString
  | RemoveLines Range [JSString] Char
  | RemoveText  Range JSString
  deriving (Typeable)

instance FromJSRef ChangeEvent where
  fromJSRef obj = runMaybeT $ do
    inner <- mtprop obj "data"
    action <- mtprop inner "action"
    range <- mtprop inner "range"
    case action :: Text of
      "insertLines" -> InsertLines range <$> mtprop inner "lines"
      "insertText"  -> InsertText  range <$> mtprop inner "text"
      "removeLines" -> RemoveLines range <$> mtprop inner "lines"
                                         <*> mtprop inner "nl"
      "removeText"  -> RemoveText  range <$> mtprop inner "text"
      _ -> MaybeT (return Nothing)

onSelectionChange :: Editor -> IO () -> IO ()
onSelectionChange e f = do
  -- TODO: open pull request on ace typescript bindings making things subtypes of EventEmitter?
  parent <- toJSRef =<< Editor.container e
  f' <- syncCallback1 (DomRetain (coerce parent)) True (\_ -> f >> return jsNull)
  s <- Editor.getSelection e
  Selection.on s "changeCursor" f'

addCommand :: Editor -> JSString -> JSString -> JSString -> IO () -> IO ()
addCommand editor name win mac f = do
  cb <- asyncCallback AlwaysRetain f
  js_addCommand editor name win mac cb

--------------------------------------------------------------------------------
-- Positions and Ranges
--
-- Note: inclusion tests consider the range to be inclusive on the
-- left (closed), and exclusive on the right (open).

data Pos = Pos
  { row :: !Int
  , column :: !Int
  }
  deriving (Show, Eq, Ord, Generic, Typeable)

data Range = Range
  { start :: !Pos
  , end :: !Pos
  }
  deriving (Show, Eq, Generic, Typeable)

data Selection = Selection
  { anchor :: !Pos
  , lead :: !Pos
  }
  deriving (Show, Eq, Generic, Typeable)

instance FromJSRef Pos       where fromJSRef = fromJSRef_generic id
instance FromJSRef Range     where fromJSRef = fromJSRef_generic id
instance FromJSRef Selection where fromJSRef = fromJSRef_generic id

instance ToJSRef Range where
  toJSRef r = js_createRange
    (row (start r))
    (column (start r))
    (row (end r))
    (column (end r))

selectionToRange :: Selection -> Range
selectionToRange sel =
  if anchor sel < lead sel
    then Range (anchor sel) (lead sel)
    else Range (lead sel) (anchor sel)

rangeToSelection :: Range -> Selection
rangeToSelection Range {..} = Selection { anchor = start, lead = end }

data RangeOrdering
  = Before
  | Intersecting
  | After
  deriving (Show, Eq, Ord, Generic, Typeable)

compareRange :: Range -> Range -> RangeOrdering
compareRange x y
  | end x < start y = Before
  | end y <= start x = After
  | otherwise = Intersecting

comparePosWithRange :: Pos -> Range -> RangeOrdering
comparePosWithRange pos range
  | pos < start range = Before
  | end range <= pos = Intersecting
  | otherwise = After

data DeltaPos = DeltaPos
  { deltaRow :: !Int
  , deltaColumn :: !Int
  }
  deriving (Show, Eq, Ord, Generic, Typeable)

subtractPos :: Pos -> Pos -> DeltaPos
subtractPos x y = DeltaPos
  { deltaRow = row x - row y
  , deltaColumn = column x - column y
  }

shiftPos :: DeltaPos -> Pos -> Pos
shiftPos d p = Pos
  { row = deltaRow d + row p
  , column = deltaColumn d + column p
  }

shiftRange :: DeltaPos -> Range -> Range
shiftRange d r = Range
  { start = shiftPos d (start r)
  , end = shiftPos d (end r)
  }

--------------------------------------------------------------------------------
-- FFI

-- Needed due to incompleteness ghcjs-from-typescript / the typescript parser
foreign import javascript unsafe "function() { return ace; }()"
  ace :: IO Ace

-- Needed due to incompleteness of typescript ace definitions

foreign import javascript unsafe "$1.on($2, $3)"
  editorOn :: Editor -> JSString -> JSFun (JSRef obj -> IO ()) -> IO ()

foreign import javascript unsafe "$1.setOption('maxLines', Infinity)"
  setMaxLinesInfty :: Editor -> IO ()

foreign import javascript unsafe "$1.addMarker($2, $3, $4, $5)"
  js_addMarker :: IEditSession -> JSRef Range -> JSString -> JSString -> JSRef Bool -> IO Int

foreign import javascript unsafe "$1.removeMarker($2)"
  js_removeMarker :: IEditSession -> Int -> IO ()

foreign import javascript unsafe "function() { var Range = ace.require('ace/range').Range; return new Range($1,$2,$3,$4); }()"
  js_createRange :: Int -> Int -> Int -> Int -> IO (JSRef Range)

foreign import javascript unsafe "$1.commands.addCommand({name:$2, bindKey:{win:$3, mac:$4, sender:'editor'}, exec:$5})"
  js_addCommand :: Editor -> JSString -> JSString -> JSString -> JSFun (IO ()) -> IO ()
