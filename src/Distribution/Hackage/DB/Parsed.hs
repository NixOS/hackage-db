{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveGeneric #-}

{- |
   Maintainer:  simons@cryp.to
   Stability:   provisional
   Portability: portable
 -}

module Distribution.Hackage.DB.Parsed where

import Distribution.Hackage.DB.Errors
import qualified Distribution.Hackage.DB.MetaData as U
import qualified Distribution.Hackage.DB.Unparsed as U
import Distribution.Hackage.DB.Utility

import GHC.Generics ( Generic )
import Control.Exception
import Data.ByteString.Lazy as BS
import Data.ByteString.Lazy.UTF8 as BS
import Data.Map as Map
import Data.Time.Clock
import Distribution.Package
import Distribution.PackageDescription
#if MIN_VERSION_Cabal(2,2,0)
import Distribution.PackageDescription.Parsec
import Distribution.Parsec.ParseResult
#else
import Distribution.PackageDescription.Parse
#endif
import Distribution.Text
import Distribution.Version

type HackageDB = Map PackageName PackageData

type PackageData = Map Version VersionData

data VersionData = VersionData { cabalFile :: !GenericPackageDescription
                               , tarballHashes :: !(Map String String)
                               }
  deriving (Show, Eq, Generic)

readTarball :: Maybe UTCTime -> FilePath -> IO HackageDB
readTarball snapshot path = fmap (parseTarball snapshot path) (BS.readFile path)

parseTarball :: Maybe UTCTime -> FilePath -> ByteString -> HackageDB
parseTarball snapshot path buf = parseDB (U.parseTarball snapshot path buf)

parseDB :: U.HackageDB -> HackageDB
parseDB = Map.mapWithKey parsePackageData

parsePackageData :: PackageName -> U.PackageData -> PackageData
parsePackageData pn (U.PackageData pv vs') =
  mapException (\e -> HackageDBPackageName pn (e :: SomeException)) $
    Map.mapWithKey (parseVersionData pn) $
      Map.filterWithKey (\v _ -> v `withinRange` vr) vs'
  where
    Dependency _ vr | BS.null pv = Dependency pn anyVersion
                    | otherwise  = parseText "preferred version range" (toString pv)

parseVersionData :: PackageName -> Version -> U.VersionData -> VersionData
parseVersionData pn v (U.VersionData cf m) =
   mapException (\e -> HackageDBPackageVersion v (e :: SomeException)) $
     VersionData gpd (parseMetaData pn v m)
  where
    gpd =
#if MIN_VERSION_Cabal(2,2,0)
          case snd $ runParseResult $ parseGenericPackageDescription $ toStrict cf of
            Right a  -> a
            Left msg -> throw (InvalidCabalFile (show msg))
#else
          case parsePackageDescription (toString cf) of
            ParseOk _ a     -> a
            ParseFailed msg -> throw (InvalidCabalFile (show msg))
#endif

parseMetaData :: PackageName -> Version -> ByteString -> Map String String
parseMetaData pn v buf | BS.null buf = Map.empty
                       | otherwise   = maybe Map.empty U.hashes targetData
  where
    targets = U.targets (U.signed (U.parseMetaData buf))
    target  = "<repo>/package/" ++ display pn ++ "-" ++ display v ++ ".tar.gz"
    targetData = Map.lookup target targets
