module Crypto.Saltine.Internal.Util where

import           Foreign.C
import           Foreign.Marshal.Alloc              (mallocBytes)
import           Foreign.Ptr
import           System.IO.Unsafe

import           Control.Applicative
import qualified Data.ByteString            as S
import           Data.ByteString                (ByteString)
import           Data.ByteString.Unsafe
import           Data.Monoid
import           GHC.Word                       (Word8)

-- | Returns @Nothing@ if the subtraction would result in an
-- underflow or a negative number.
safeSubtract :: (Ord a, Num a) => a -> a -> Maybe a
x `safeSubtract` y = if y > x then Nothing else Just (x - y)

-- | @snd . cycleSucc@ computes the 'succ' of a 'Bounded', 'Eq' 'Enum'
-- with wraparound. The @fst . cycleSuc@ is whether the wraparound
-- occurred (i.e. @fst . cycleSucc == (== maxBound)@).
cycleSucc :: (Bounded a, Enum a, Eq a) => a -> (Bool, a)
cycleSucc a = (top, if top then minBound else succ a)
  where top = a == maxBound

-- | Treats a 'ByteString' as a little endian bitstring and increments
-- it.
nudgeBS :: ByteString -> ByteString
nudgeBS i = fst $ S.unfoldrN (S.length i) go (True, i) where
  go (toSucc, bs) = do
    (hd, tl)      <- S.uncons bs
    let (top, hd') = cycleSucc hd

    if   toSucc
    then return (hd', (top, tl))
    else return (hd, (top && toSucc, tl))

-- | Computes the orbit of a endomorphism... in a very brute force
-- manner. Exists just for the below property.
--
-- prop> length . orbit nudgeBS . S.pack . replicate 0 == (256^)
orbit :: Eq a => (a -> a) -> a -> [a]
orbit f a0 = orbit' (f a0) where
  orbit' a = if a == a0 then [a0] else a : orbit' (f a)

-- | 0-pad a 'ByteString'
pad :: Int -> ByteString -> ByteString
pad n = mappend (S.replicate n 0)

-- | Remove a 0-padding from a 'ByteString'
unpad :: Int -> ByteString -> ByteString
unpad = S.drop

-- | Converts a C-convention errno to an Either
handleErrno :: CInt -> (a -> Either String a)
handleErrno err a = case err of
  0  -> Right a
  -1 -> Left "failed"
  n  -> Left ("unexpected error code: " ++ show n)

unsafeDidSucceed :: IO CInt -> Bool
unsafeDidSucceed = go . unsafePerformIO
  where go 0 = True
        go _ = False

-- | Convenience function for accessing constant C strings
constByteStrings :: [ByteString] -> ([CStringLen] -> IO b) -> IO b
constByteStrings =
  foldr (\v kk -> \k -> (unsafeUseAsCStringLen v) (\a -> kk (\as -> k (a:as)))) ($ [])

-- | Slightly safer cousin to 'buildUnsafeByteString' that remains in the
-- 'IO' monad.
buildUnsafeByteString' :: Int -> (Ptr CChar -> IO b) -> IO (b, ByteString)
buildUnsafeByteString' n k = do
  ph  <- mallocBytes n
  bs  <- unsafePackMallocCStringLen (ph, fromIntegral n)
  out <- unsafeUseAsCString bs k
  return (out, bs)

-- | Extremely unsafe function, use with utmost care! Builds a new
-- ByteString using a ccall which is given access to the raw underlying
-- pointer. Overwrites are UNCHECKED and 'unsafePerformIO' is used so
-- it's difficult to predict the timing of the 'ByteString' creation.
buildUnsafeByteString :: Int -> (Ptr CChar -> IO b) -> (b, ByteString)
buildUnsafeByteString n = unsafePerformIO . buildUnsafeByteString' n

-- | Build a sized random 'ByteString' using Sodium's bindings to
-- @/dev/urandom@.
randomByteString :: Int -> IO ByteString
randomByteString n =
  snd <$> buildUnsafeByteString' n (`c_randombytes_buf` fromIntegral n)

-- | To prevent a dependency on package 'errors'
hush :: Either s a -> Maybe a
hush = either (const Nothing) Just

foreign import ccall "randombytes_buf"
  c_randombytes_buf :: Ptr CChar -> CInt -> IO ()

-- | Constant time memory comparison
foreign import ccall unsafe "sodium_memcmp"
  c_sodium_memcmp
    :: Ptr CChar -- a
    -> Ptr CChar -- b
    -> CInt   -- Length
    -> IO CInt

foreign import ccall unsafe "sodium_malloc"
  c_sodium_malloc
    :: CSize -> IO (Ptr a)

foreign import ccall unsafe "sodium_free"
  c_sodium_free
    :: Ptr Word8 -> IO ()

-- | Not sure yet what to use this for
buildUnsafeScrubbedByteString' :: Int -> (Ptr CChar -> IO b) -> IO (b,ByteString)
buildUnsafeScrubbedByteString' n k = do
    p <- c_sodium_malloc (fromIntegral n)

    bs <- unsafePackCStringFinalizer p n (c_sodium_free p)
    out <- unsafeUseAsCString bs k
    pure (out,bs)

-- | Not sure yet what to use this for
buildUnsafeScrubbedByteString :: Int -> (Ptr CChar -> IO b) -> (b,ByteString)
buildUnsafeScrubbedByteString n = unsafePerformIO . buildUnsafeScrubbedByteString' n

-- | Constant-time comparison
compare :: ByteString -> ByteString -> Bool
compare a b =
    (S.length a == S.length b) && unsafePerformIO (constByteStrings [a, b] $ \
        [(bsa, _), (bsb,_)] ->
            (== 0) <$> c_sodium_memcmp bsa bsb (fromIntegral $ S.length a))
