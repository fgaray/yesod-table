{-| Table building library for yesod

    This library is intended to be brought in by a qualified import
    along with type import as follows:

> import qualified Yesod.Table as Table
> import Yesod.Table (Table)

    There are two types in this module: 'Table' and 'Column'. Roughly, a 
    'Table' is just a list of 'Column's. Except in the case of rendering
    a 'Table', you should not need to use the data constructors of 
    either of these types. (In fact, you should not need to refer to 
    the type 'Column' either). Instead, you should use the functions
    'singleton', 'text', 'int', etc. to build singleton 'Table's
    (a 'Table' with only one 'Column') and use monoidal concatenation
    to combine these.

    It is important to note that, as defined in this library, 'Table' 
    refers to a blueprint for an HTML table, not a complete table with 
    content.

    If you want to define your own table rendering function (and it's
    likely that you will), then you will need the aforementioned data 
    constructors. You can look at the source of 'buildBootstrap' for 
    an example of how to do this.
-}
module Yesod.Table 
  ( Table(..)
  , Column(..)
  , buildBootstrap
  , singleton
  , widget
  , text
  , string
  , int
  , linked
  , when
  , whenWith
  , maybe
  , maybeWith
  ) where

import Prelude hiding (mapM_,when,maybe)
import Yesod.Core
import Yesod.Core.Widget
import Data.Functor.Contravariant
import Data.Functor.Contravariant.Divisible
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as Text

-- import Control.Monad
import Data.Foldable (forM_, mapM_)
import Data.Monoid
import qualified Data.Maybe as M

newtype Table site a = Table (Seq (Column site a))
  deriving (Monoid)

data Column site a = Column
  { header :: !(WidgetT site IO ())
  , cell :: !(a -> WidgetT site IO ()) 
  }

instance Contravariant (Column site) where
  contramap g (Column h c) = Column h (c . g)

instance Contravariant (Table site) where
  contramap g (Table cols) = Table (fmap (contramap g) cols)

instance Divisible (Table site) where
  conquer = mempty
  divide f (Table aCols) (Table bCols) = Table $ 
    (fmap (contramap (fst . f)) aCols) <> 
    (fmap (contramap (snd . f)) bCols)

-- | This is the most primitive and essential operation for building a 'Table'.
--   All other table-building functions (such as 'widget', 'text', and 'linked')
--   build on top of 'singleton'. One common trend in the convenience functions 
--   is that they accept 'Text' as the table header. This is done because I have 
--   found that it is uncommon to need the full power of HTML in the header.
--   Just know that if you need it, this function is the only way to get it.
--   The first argument is a widget that is the
--   content to be displayed in the table header. The second argument is the
--   a function that consumes a value to produce the content shown in a row of the
--   table body. 
singleton :: WidgetT site IO () -> (a -> WidgetT site IO ()) -> Table site a
singleton c h = Table (Seq.singleton (Column c h))

-- | This is the same as 'singleton', with the convenience of accepting 
--   the table header as 'Text'.
widget :: Text -> (a -> WidgetT site IO ()) -> Table site a
widget h c = singleton (textToWidget h) c

-- | Identical to 'widget', with the convenience of accepting 
--   the table cell content as 'Text'.
text :: Text -> (a -> Text) -> Table site a
text h c = singleton (textToWidget h) (textToWidget . c)

-- | Identical to 'widget', with the convenience of accepting 
--   the table cell content as 'String'.
string :: Text -> (a -> String) -> Table site a
string h c = singleton (textToWidget h) (textToWidget . Text.pack . c)

-- | Identical to 'widget', with the convenience of accepting 
--   the table cell content as 'Int'.
int :: Text -> (a -> Int) -> Table site a
int h c = singleton (textToWidget h) (textToWidget . Text.pack . show . c)

-- | Convenience function for building a plaintext link where the link text and the route are 
--   determined by the row of data. If you are working with an 
--   @Entity@ (from @persistent@) and your foundation type 
--   is named @App@ you may want something like this:
--
--   > myTable :: Table App (Entity Foo)
--   > myTable = mempty
--   >   <> Table.linked "Name" (fooName . entityVal) (FooEditR . entityKey)
--   >   <> Table.int    "Size" (fooSize . entityVal)
--
--   This is the blueprint for a two-column table. The first column is
--   a link for editing the Foo, and the linked text is the @Foo@ name.
--   The second column is just a number representing the size of the @Foo@
--   shown as plaintext.
linked :: Text               -- ^ Column name
       -> (a -> Text)        -- ^ Text extracting function
       -> (a -> Route site)  -- ^ Route extracting function
       -> Table site a       
linked h propFunc routeFunc = singleton (textToWidget h) render
  where render a = asWidgetIO [whamlet|<a href=@{routeFunc a}>#{propFunc a}|]

-- | Prevents showing values
--   in a 'Table' if a condition is not met. Example
--
--   > myTable :: Table App Person
--   > myTable = mempty
--   >   <> Table.text "Name" personName
--   >   <> Table.when (\p -> personAge p > 21) (Table.int "Age" personAge)
--
--   In this example, the table header Age will always show up with its
--   corresponding column, but any row for a person under 21 will have
--   a empty value for that column. The effect can be more profound:
--   
--   > myTable :: Table App Person
--   > myTable = mempty
--   >   <> Table.text "Name" personName
--   >   <> Table.when (\p -> personAge p > 21) (mempty
--   >     <> Table.text "Favorite Color" personFavoriteColor
--   >     <> Table.text "Address" personAddress
--   >     <> Table.linked "Profile Page" (const "Profile") (ProfileR . personUsername)
--   >     )
--
--   This second example does not show information for any of the last three 
--   columns if the person is under 21. The columns themselves though are always 
--   present regardless of whether or not any values satisfy the predicate.
when :: (a -> Bool)   -- ^ Predicate
     -> Table site a  -- ^ Existing table
     -> Table site a  
when = whenWith mempty

whenWith :: WidgetT site IO () -- ^ Contents when predicate is false
        -> (a -> Bool)        -- ^ Predicate
        -> Table site a       -- ^ Existing table
        -> Table site a  
whenWith defContents pred (Table cols) = Table $ fmap (\(Column h c) -> Column h (\a -> if pred a then c a else defContents)) cols


-- | Promote a 'Table' to take 'Maybe' values. When the data
--   passed in matches the 'Just' data constructor, the row 
--   is presented as it would be with the original table.
--   When it is 'Nothing', the row is empty.
maybe :: Table site a -> Table site (Maybe a)
maybe = maybeWith mempty

maybeWith :: WidgetT site IO () -> Table site a -> Table site (Maybe a)
maybeWith defContents (Table cols) = Table $ fmap (\(Column h c) -> Column h (M.maybe defContents c)) cols

-- | From a 'Table' blueprint and a list of the data that it accepts,
--   build the actual html needed to visualize this data. This particular 
--   rendering of the data applies the classes @table@ and @table-striped@
--   to the @<table>@ element. If you are using bootstrap, this means that
--   it will be formatted in the bootstrap way. If not, the table will still 
--   render correctly, but the classes will be renamed. I'm open to pull requests
--   for supporting other common table formats out of the box.
buildBootstrap :: Table site a -> [a] -> WidgetT site IO ()
buildBootstrap (Table cols) vals = table $ do
  thead $ mapM_ (th . header) cols
  tbody $ forM_ vals $ \val -> tr $ forM_ cols $ \col -> td $ cell col val
  where table b  = asWidgetIO [whamlet|
                     <table.table.table-striped>^{b}
                   |]
        thead b  = asWidgetIO [whamlet|
                     <thead>
                       <tr>
                         ^{b}
                   |]
        td b     = asWidgetIO [whamlet|
                     <td>^{b}
                   |]
        th b     = asWidgetIO [whamlet|
                     <th>^{b}
                   |]
        tbody b  = asWidgetIO [whamlet|
                     <tbody>^{b}
                   |]
        tr b     = asWidgetIO [whamlet|
                     <tr>^{b}
                   |]

-- This function is used to constrain types so that
-- GHC 7.10 will quit giving me errors about
-- needing to use FlexibleContexts.
asWidgetIO :: WidgetT site IO () -> WidgetT site IO ()
asWidgetIO = id

textToWidget :: Text -> WidgetT site IO ()
textToWidget = toWidget . toHtml

