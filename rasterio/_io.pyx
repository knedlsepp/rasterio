# cython: boundscheck=False
"""Rasterio input/output."""

from __future__ import absolute_import

import logging
import os
import os.path
import sys
import uuid
import warnings

import numpy as np

from rasterio._base import tastes_like_gdal
from rasterio._drivers import driver_count, GDALEnv
from rasterio._err import (
    CPLErrors, GDALError, CPLE_OpenFailedError, CPLE_IllegalArgError)
from rasterio.crs import CRS
from rasterio.compat import text_type, string_types
from rasterio import dtypes
from rasterio.enums import ColorInterp, MaskFlags, Resampling
from rasterio.errors import DriverRegistrationError
from rasterio.errors import RasterioIOError
from rasterio.errors import NodataShadowWarning
from rasterio.sample import sample_gen
from rasterio.transform import Affine
from rasterio.vfs import parse_path, vsi_path
from rasterio import windows

cimport numpy as np

from rasterio._base cimport _osr_from_crs, get_driver_name, DatasetBase
from rasterio._gdal cimport (
    CPLFree, CPLMalloc, CSLDestroy, CSLDuplicate, CSLFetchNameValue,
    CSLSetNameValue, GDALBuildOverviews, GDALClose, GDALCreate,
    GDALCreateColorTable, GDALCreateCopy, GDALCreateMaskBand,
    GDALDatasetRasterIO, GDALDestroyColorTable, GDALFillRaster,
    GDALGetDatasetDriver, GDALGetDatasetDriver, GDALGetDescription,
    GDALGetDriverByName, GDALGetDriverShortName, GDALGetMaskBand,
    GDALGetMaskFlags, GDALGetMetadata, GDALGetRasterBand, GDALGetRasterCount,
    GDALGetRasterXSize, GDALGetRasterYSize, GDALOpen, GDALRasterIO,
    GDALSetColorEntry, GDALSetDescription, GDALSetGeoTransform,
    GDALSetMetadata, GDALSetProjection, GDALSetRasterColorInterpretation,
    GDALSetRasterColorTable, GDALSetRasterNoDataValue,
    GDALSetRasterNoDataValue, GDALSetRasterUnitType,
    OSRDestroySpatialReference, OSRExportToWkt, OSRFixup, OSRImportFromEPSG,
    OSRImportFromProj4, OSRNewSpatialReference, OSRSetFromUserInput,
    VSIGetMemFileBuffer, vsi_l_offset)

include "gdal.pxi"


log = logging.getLogger(__name__)


cdef bint in_dtype_range(value, dtype):
    """Returns True if value is in the range of dtype, else False."""
    infos = {
        'c': np.finfo,
        'f': np.finfo,
        'i': np.iinfo,
        'u': np.iinfo,
        # Cython 0.22 returns dtype.kind as an int and will not cast to a char
        99: np.finfo,
        102: np.finfo,
        105: np.iinfo,
        117: np.iinfo
    }
    key = np.dtype(dtype).kind
    if np.isnan(value):
        return key in ('c', 'f', 99, 102)

    rng = infos[key](dtype)
    return rng.min <= value <= rng.max

# Single band IO functions.

cdef int io_ubyte(
        GDALRasterBandH band,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.uint8_t[:, :] buffer):
    with nogil:
        return GDALRasterIO(
            band, mode, xoff, yoff, width, height,
            &buffer[0, 0], buffer.shape[1], buffer.shape[0], 1, 0, 0)

cdef int io_uint16(
        GDALRasterBandH band,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.uint16_t[:, :] buffer):
    with nogil:
        return GDALRasterIO(
            band, mode, xoff, yoff, width, height,
            &buffer[0, 0], buffer.shape[1], buffer.shape[0], 2, 0, 0)

cdef int io_int16(
        GDALRasterBandH band,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.int16_t[:, :] buffer):
    with nogil:
        return GDALRasterIO(
            band, mode, xoff, yoff, width, height,
            &buffer[0, 0], buffer.shape[1], buffer.shape[0], 3, 0, 0)

cdef int io_uint32(
        GDALRasterBandH band,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.uint32_t[:, :] buffer):
    with nogil:
        return GDALRasterIO(
            band, mode, xoff, yoff, width, height,
            &buffer[0, 0], buffer.shape[1], buffer.shape[0], 4, 0, 0)

cdef int io_int32(
        GDALRasterBandH band,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.int32_t[:, :] buffer):
    with nogil:
        return GDALRasterIO(
            band, mode, xoff, yoff, width, height,
            &buffer[0, 0], buffer.shape[1], buffer.shape[0], 5, 0, 0)

cdef int io_float32(
        GDALRasterBandH band,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.float32_t[:, :] buffer):
    with nogil:
        return GDALRasterIO(
            band, mode, xoff, yoff, width, height,
            &buffer[0, 0], buffer.shape[1], buffer.shape[0], 6, 0, 0)

cdef int io_float64(
        GDALRasterBandH band,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.float64_t[:, :] buffer):
    with nogil:
        return GDALRasterIO(
            band, mode, xoff, yoff, width, height,
            &buffer[0, 0], buffer.shape[1], buffer.shape[0], 7, 0, 0)

# The multi-band IO functions.

cdef int io_multi_ubyte(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.uint8_t[:, :, :] buffer,
        long[:] indexes,
        int count) nogil:
    cdef int i, retval=0
    cdef GDALRasterBandH band
    cdef int *bandmap
    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buffer[0, 0, 0],
            buffer.shape[2], buffer.shape[1], 1, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)
    return retval

cdef int io_multi_uint16(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.uint16_t[:, :, :] buf,
        long[:] indexes,
        int count) nogil:
    cdef int i, retval=0
    cdef GDALRasterBandH band = NULL
    cdef int *bandmap
    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buf[0, 0, 0], buf.shape[2],
            buf.shape[1], 2, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)
    return retval

cdef int io_multi_int16(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.int16_t[:, :, :] buf,
        long[:] indexes,
        int count) nogil:
    cdef int i, retval=0
    cdef GDALRasterBandH band = NULL
    cdef int *bandmap
    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buf[0, 0, 0], buf.shape[2],
            buf.shape[1], 3, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)
    return retval

cdef int io_multi_uint32(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.uint32_t[:, :, :] buf,
        long[:] indexes,
        int count) nogil:
    cdef int i, retval=0
    cdef GDALRasterBandH band = NULL
    cdef int *bandmap
    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buf[0, 0, 0], buf.shape[2],
            buf.shape[1], 4, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)
    return retval

cdef int io_multi_int32(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.int32_t[:, :, :] buf,
        long[:] indexes,
        int count) nogil:
    cdef int i, retval=0
    cdef GDALRasterBandH band = NULL
    cdef int *bandmap
    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buf[0, 0, 0], buf.shape[2],
            buf.shape[1], 5, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)
    return retval


cdef int io_multi_float32(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.float32_t[:, :, :] buf,
        long[:] indexes,
        int count) nogil:
    cdef int i, retval=0
    cdef GDALRasterBandH band = NULL
    cdef int *bandmap
    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buf[0, 0, 0], buf.shape[2],
            buf.shape[1], 6, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)
    return retval

cdef int io_multi_float64(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.float64_t[:, :, :] buf,
        long[:] indexes,
        int count) nogil:

    cdef int i, retval=0
    cdef GDALRasterBandH band = NULL
    cdef int *bandmap
    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buf[0, 0, 0], buf.shape[2],
            buf.shape[1], 7, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)
    return retval

cdef int io_multi_cint16(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.complex_t[:, :, :] out,
        long[:] indexes,
        int count):
    cdef int retval=0
    cdef int *bandmap
    cdef int I, J, K
    cdef int i, j, k
    cdef np.int16_t real, imag

    buf = np.zeros(
            (out.shape[0], 2*out.shape[2]*out.shape[1]),
            dtype=np.int16)
    cdef np.int16_t[:, :] buf_view = buf

    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buf_view[0, 0],
            out.shape[2], out.shape[1], 8, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)

        if retval > 0:
            return retval

        I = out.shape[0]
        J = out.shape[1]
        K = out.shape[2]
        for i in range(I):
            for j in range(J):
                for k in range(K):
                    real = buf_view[i, 2*(j*K+k)]
                    imag = buf_view[i, 2*(j*K+k)+1]
                    out[i,j,k].real = real
                    out[i,j,k].imag = imag

    return retval

cdef int io_multi_cint32(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.complex_t[:, :, :] out,
        long[:] indexes,
        int count):

    cdef int retval=0
    cdef int *bandmap
    cdef int I, J, K
    cdef int i, j, k
    cdef np.int32_t real, imag

    buf = np.empty(
            (out.shape[0], 2*out.shape[2]*out.shape[1]),
            dtype=np.int32)
    cdef np.int32_t[:, :] buf_view = buf

    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buf_view[0, 0],
            out.shape[2], out.shape[1], 9, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)

        if retval > 0:
            return retval

        I = out.shape[0]
        J = out.shape[1]
        K = out.shape[2]
        for i in range(I):
            for j in range(J):
                for k in range(K):
                    real = buf_view[i, 2*(j*K+k)]
                    imag = buf_view[i, 2*(j*K+k)+1]
                    out[i,j,k].real = real
                    out[i,j,k].imag = imag

    return retval

cdef int io_multi_cfloat32(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.complex64_t[:, :, :] out,
        long[:] indexes,
        int count):

    cdef int retval=0
    cdef int *bandmap
    cdef int I, J, K
    cdef int i, j, k
    cdef np.float32_t real, imag

    buf = np.empty(
            (out.shape[0], 2*out.shape[2]*out.shape[1]),
            dtype=np.float32)
    cdef np.float32_t[:, :] buf_view = buf

    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buf_view[0, 0],
            out.shape[2], out.shape[1], 10, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)

        if retval > 0:
            return retval

        I = out.shape[0]
        J = out.shape[1]
        K = out.shape[2]
        for i in range(I):
            for j in range(J):
                for k in range(K):
                    real = buf_view[i, 2*(j*K+k)]
                    imag = buf_view[i, 2*(j*K+k)+1]
                    out[i,j,k].real = real
                    out[i,j,k].imag = imag

    return retval

cdef int io_multi_cfloat64(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.complex128_t[:, :, :] out,
        long[:] indexes,
        int count):

    cdef int retval=0
    cdef int *bandmap
    cdef int I, J, K
    cdef int i, j, k
    cdef np.float64_t real, imag

    buf = np.empty(
            (out.shape[0], 2*out.shape[2]*out.shape[1]),
            dtype=np.float64)
    cdef np.float64_t[:, :] buf_view = buf

    with nogil:
        bandmap = <int *>CPLMalloc(count*sizeof(int))
        for i in range(count):
            bandmap[i] = indexes[i]
        retval = GDALDatasetRasterIO(
            hds, mode, xoff, yoff, width, height, &buf_view[0, 0],
            out.shape[2], out.shape[1], 11, count, bandmap, 0, 0, 0)
        CPLFree(bandmap)

        if retval > 0:
            return retval

        I = out.shape[0]
        J = out.shape[1]
        K = out.shape[2]
        for i in range(I):
            for j in range(J):
                for k in range(K):
                    real = buf_view[i, 2*(j*K+k)]
                    imag = buf_view[i, 2*(j*K+k)+1]
                    out[i,j,k].real = real
                    out[i,j,k].imag = imag

    return retval


cdef int io_multi_mask(
        GDALDatasetH hds,
        int mode,
        int xoff,
        int yoff,
        int width,
        int height,
        np.uint8_t[:, :, :] buffer,
        long[:] indexes,
        int count):
    cdef int i, j, retval=0
    cdef GDALRasterBandH band
    cdef GDALRasterBandH hmask

    for i in range(count):
        j = indexes[i]
        band = GDALGetRasterBand(hds, j)
        if band == NULL:
            raise ValueError("Null band")
        hmask = GDALGetMaskBand(band)
        if hmask == NULL:
            raise ValueError("Null mask band")
        with nogil:
            retval = GDALRasterIO(
                hmask, mode, xoff, yoff, width, height,
                &buffer[i, 0, 0], buffer.shape[2], buffer.shape[1], 1, 0, 0)
            if retval:
                break
    return retval


cdef int io_auto(image, GDALRasterBandH band, bint write):
    """
    Convenience function to handle IO with a GDAL band and a 2D numpy image

    :param image: a numpy 2D image
    :param band: an instance of GDALGetRasterBand
    :param write: 1 (True) uses write mode (writes image into band),
                  0 (False) uses read mode (reads band into image)
    :return: the return value from the data-type specific IO function
    """

    cdef int ndims = len(image.shape)
    cdef int height = image.shape[-2]
    cdef int width = image.shape[-1]
    cdef int count
    cdef long[:] indexes
    dtype_name = image.dtype.name

    if ndims == 2:
        if dtype_name == "float32":
            return io_float32(band, write, 0, 0, width, height, image)
        elif dtype_name == "float64":
            return io_float64(band, write, 0, 0, width, height, image)
        elif dtype_name == "uint8":
            return io_ubyte(band, write, 0, 0, width, height, image)
        elif dtype_name == "int16":
            return io_int16(band, write, 0, 0, width, height, image)
        elif dtype_name == "int32":
            return io_int32(band, write, 0, 0, width, height, image)
        elif dtype_name == "uint16":
            return io_uint16(band, write, 0, 0, width, height, image)
        elif dtype_name == "uint32":
            return io_uint32(band, write, 0, 0, width, height, image)
        else:
            raise ValueError("Image dtype is not supported for this function."
                             "Must be float32, float64, int16, int32, uint8, "
                             "uint16, or uint32")
    elif ndims == 3:
        count = image.shape[0]
        indexes = np.arange(1, count + 1)

        dtype_name = image.dtype.name

        if dtype_name == "float32":
            return io_multi_float32(band, write, 0, 0, width, height, image,
                                    indexes, count)
        elif dtype_name == "float64":
            return io_multi_float64(band, write, 0, 0, width, height, image,
                                    indexes, count)
        elif dtype_name == "uint8":
            return io_multi_ubyte(band, write, 0, 0, width, height, image,
                                    indexes, count)
        elif dtype_name == "int16":
            return io_multi_int16(band, write, 0, 0, width, height, image,
                                    indexes, count)
        elif dtype_name == "int32":
            return io_multi_int32(band, write, 0, 0, width, height, image,
                                    indexes, count)
        elif dtype_name == "uint16":
            return io_multi_uint16(band, write, 0, 0, width, height, image,
                                    indexes, count)
        elif dtype_name == "uint32":
            return io_multi_uint32(band, write, 0, 0, width, height, image,
                                    indexes, count)
        else:
            raise ValueError("Image dtype is not supported for this function."
                             "Must be float32, float64, int16, int32, uint8, "
                             "uint16, or uint32")

    else:
        raise ValueError("Specified image must have 2 or 3 dimensions")


cdef class DatasetReaderBase(DatasetBase):

    def read(self, indexes=None, out=None, window=None, masked=False,
            out_shape=None, boundless=False):
        """Read raster bands as a multidimensional array

        Parameters
        ----------
        indexes : list of ints or a single int, optional
            If `indexes` is a list, the result is a 3D array, but is
            a 2D array if it is a band index number.

        out : numpy ndarray, optional
            As with Numpy ufuncs, this is an optional reference to an
            output array with the same dimensions and shape into which
            data will be placed.

            *Note*: the method's return value may be a view on this
            array. In other words, `out` is likely to be an
            incomplete representation of the method's results.

            Cannot combined with `out_shape`.

        out_shape : tuple, optional
            A tuple describing the output array's shape.  Allows for decimated
            reads without constructing an output Numpy array.

            Cannot combined with `out`.

        window : a pair (tuple) of pairs of ints, optional
            The optional `window` argument is a 2 item tuple. The first
            item is a tuple containing the indexes of the rows at which
            the window starts and stops and the second is a tuple
            containing the indexes of the columns at which the window
            starts and stops. For example, ((0, 2), (0, 2)) defines
            a 2x2 window at the upper left of the raster dataset.

        masked : bool, optional
            If `masked` is `True` the return value will be a masked
            array. Otherwise (the default) the return value will be a
            regular array. Masks will be exactly the inverse of the
            GDAL RFC 15 conforming arrays returned by read_masks().

        boundless : bool, optional (default `False`)
            If `True`, windows that extend beyond the dataset's extent
            are permitted and partially or completely filled arrays will
            be returned as appropriate.

        Returns
        -------
        Numpy ndarray or a view on a Numpy ndarray

        Note: as with Numpy ufuncs, an object is returned even if you
        use the optional `out` argument and the return value shall be
        preferentially used by callers.
        """

        cdef GDALRasterBandH band = NULL

        return2d = False
        if indexes is None:
            indexes = self.indexes
        elif isinstance(indexes, int):
            indexes = [indexes]
            return2d = True
            if out is not None and out.ndim == 2:
                out.shape = (1,) + out.shape
        if not indexes:
            raise ValueError("No indexes to read")

        check_dtypes = set()
        nodatavals = []
        # Check each index before processing 3D array
        for bidx in indexes:
            if bidx not in self.indexes:
                raise IndexError("band index out of range")
            idx = self.indexes.index(bidx)

            dtype = self.dtypes[idx]
            check_dtypes.add(dtype)

            ndv = self._nodatavals[idx]
            # Change given nodatavals to the closest value that
            # can be represented by this band's data type to
            # match GDAL's strategy.
            if ndv is not None:
                if np.dtype(dtype).kind in ('i', 'u'):
                    info = np.iinfo(dtype)
                    dt_min, dt_max = info.min, info.max
                elif np.dtype(dtype).kind in ('f', 'c'):
                    info = np.finfo(dtype)
                    dt_min, dt_max = info.min, info.max
                else:
                    dt_min, dt_max = False, True
                if ndv < dt_min:
                    ndv = dt_min
                elif ndv > dt_max:
                    ndv = dt_max

            nodatavals.append(ndv)

        # Mixed dtype reads are not supported at this time.
        if len(check_dtypes) > 1:
            raise ValueError("more than one 'dtype' found")
        elif len(check_dtypes) == 0:
            dtype = self.dtypes[0]
        else:
            dtype = check_dtypes.pop()

        # Get the natural shape of the read window, boundless or not.
        win_shape = (len(indexes),)
        if window:
            if boundless:
                win_shape += (
                        window[0][1]-window[0][0], window[1][1]-window[1][0])
            else:
                window = windows.crop(
                    windows.evaluate(window, self.height, self.width),
                    self.height, self.width
                )
                (r_start, r_stop), (c_start, c_stop) = window
                win_shape += (r_stop - r_start, c_stop - c_start)
        else:
            win_shape += self.shape

        if out is not None and out_shape is not None:
            raise ValueError("out and out_shape are exclusive")
        elif out_shape is not None:
            if len(out_shape) == 2:
                out_shape = (1,) + out_shape
            out = np.empty(out_shape, dtype=dtype)

        if out is not None:
            if out.dtype != dtype:
                raise ValueError(
                    "the array's dtype '%s' does not match "
                    "the file's dtype '%s'" % (out.dtype, dtype))
            if out.shape[0] != win_shape[0]:
                raise ValueError(
                    "'out' shape %s does not match window shape %s" %
                    (out.shape, win_shape))

        # Masking
        # -------
        #
        # If masked is True, we check the GDAL mask flags using
        # GDALGetMaskFlags. If GMF_ALL_VALID for all bands, we do not
        # call read_masks(), but pass `mask=False` to the masked array
        # constructor. Else, we read the GDAL mask bands using
        # read_masks(), invert them and use them in constructing masked
        # arrays.

        if masked:

            mask_flags = [0]*self.count
            for i, j in zip(range(self.count), self.indexes):
                band = self.band(j)
                mask_flags[i] = GDALGetMaskFlags(band)

            all_valid = all([flag & 0x01 == 1 for flag in mask_flags])

            log.debug("all_valid: %s", all_valid)
            log.debug("mask_flags: %r", mask_flags)

        if out is None:
            out = np.zeros(win_shape, dtype)
            for ndv, arr in zip(
                    nodatavals, out if len(out.shape) == 3 else [out]):
                if ndv is not None:
                    arr.fill(ndv)

        # We can jump straight to _read() in some cases. We can ignore
        # the boundless flag if there's no given window.
        if not boundless or not window:
            out = self._read(indexes, out, window, dtype)

            if masked:
                if all_valid:
                    mask = np.ma.nomask
                else:
                    mask = np.empty(out.shape, 'uint8')
                    mask = ~self._read(
                        indexes, mask, window, 'uint8', masks=True
                        ).astype('bool')

                kwds = {'mask': mask}
                # Set a fill value only if the read bands share a
                # single nodata value.
                if len(set(nodatavals)) == 1:
                    if nodatavals[0] is not None:
                        kwds['fill_value'] = nodatavals[0]
                out = np.ma.array(out, **kwds)

        else:
            # Compute the overlap between the dataset and the boundless window.
            overlap = ((
                max(min(window[0][0], self.height), 0),
                max(min(window[0][1], self.height), 0)), (
                max(min(window[1][0], self.width), 0),
                max(min(window[1][1], self.width), 0)))

            if overlap != ((0, 0), (0, 0)):
                # Prepare a buffer.
                window_h, window_w = win_shape[-2:]
                overlap_h = overlap[0][1] - overlap[0][0]
                overlap_w = overlap[1][1] - overlap[1][0]
                scaling_h = float(out.shape[-2:][0])/window_h
                scaling_w = float(out.shape[-2:][1])/window_w
                buffer_shape = (
                        int(round(overlap_h*scaling_h)),
                        int(round(overlap_w*scaling_w)))
                data = np.empty(win_shape[:-2] + buffer_shape, dtype)
                data = self._read(indexes, data, overlap, dtype)

                if masked:
                    mask = np.empty(win_shape[:-2] + buffer_shape, 'uint8')
                    mask = ~self._read(
                        indexes, mask, overlap, 'uint8', masks=True
                        ).astype('bool')
                    kwds = {'mask': mask}
                    if len(set(nodatavals)) == 1:
                        if nodatavals[0] is not None:
                            kwds['fill_value'] = nodatavals[0]
                    data = np.ma.array(data, **kwds)

            else:
                data = None
                if masked:
                    kwds = {'mask': True}
                    if len(set(nodatavals)) == 1:
                        if nodatavals[0] is not None:
                            kwds['fill_value'] = nodatavals[0]
                    out = np.ma.array(out, **kwds)

            if data is not None:
                # Determine where to put the data in the output window.
                data_h, data_w = buffer_shape
                roff = 0
                coff = 0
                if window[0][0] < 0:
                    roff = int(-window[0][0] * scaling_h)
                if window[1][0] < 0:
                    coff = int(-window[1][0] * scaling_w)

                for dst, src in zip(
                        out if len(out.shape) == 3 else [out],
                        data if len(data.shape) == 3 else [data]):
                    dst[roff:roff+data_h, coff:coff+data_w] = src

                if masked:
                    if not hasattr(out, 'mask'):
                        kwds = {'mask': True}
                        if len(set(nodatavals)) == 1:
                            if nodatavals[0] is not None:
                                kwds['fill_value'] = nodatavals[0]
                        out = np.ma.array(out, **kwds)

                    for dst, src in zip(
                            out.mask if len(out.shape) == 3 else [out.mask],
                            data.mask if len(data.shape) == 3 else [data.mask]):
                        dst[roff:roff+data_h, coff:coff+data_w] = src

        if return2d:
            out.shape = out.shape[1:]

        return out


    def read_masks(self, indexes=None, out=None, out_shape=None, window=None,
                   boundless=False):
        """Read raster band masks as a multidimensional array

        Parameters
        ----------
        indexes : list of ints or a single int, optional
            If `indexes` is a list, the result is a 3D array, but is
            a 2D array if it is a band index number.

        out : numpy ndarray, optional
            As with Numpy ufuncs, this is an optional reference to an
            output array with the same dimensions and shape into which
            data will be placed.

            *Note*: the method's return value may be a view on this
            array. In other words, `out` is likely to be an
            incomplete representation of the method's results.

            Cannot combine with `out_shape`.

        out_shape : tuple, optional
            A tuple describing the output array's shape.  Allows for decimated
            reads without constructing an output Numpy array.

            Cannot combined with `out`.

        window : a pair (tuple) of pairs of ints, optional
            The optional `window` argument is a 2 item tuple. The first
            item is a tuple containing the indexes of the rows at which
            the window starts and stops and the second is a tuple
            containing the indexes of the columns at which the window
            starts and stops. For example, ((0, 2), (0, 2)) defines
            a 2x2 window at the upper left of the raster dataset.

        boundless : bool, optional (default `False`)
            If `True`, windows that extend beyond the dataset's extent
            are permitted and partially or completely filled arrays will
            be returned as appropriate.

        Returns
        -------
        Numpy ndarray or a view on a Numpy ndarray

        Note: as with Numpy ufuncs, an object is returned even if you
        use the optional `out` argument and the return value shall be
        preferentially used by callers.
        """

        return2d = False
        if indexes is None:
            indexes = self.indexes
        elif isinstance(indexes, int):
            indexes = [indexes]
            return2d = True
            if out is not None and out.ndim == 2:
                out.shape = (1,) + out.shape
        if not indexes:
            raise ValueError("No indexes to read")

        # Get the natural shape of the read window, boundless or not.
        win_shape = (len(indexes),)
        if window:
            if boundless:
                win_shape += (
                        window[0][1]-window[0][0], window[1][1]-window[1][0])
            else:
                w = windows.evaluate(window, self.height, self.width)
                minr = min(max(w[0][0], 0), self.height)
                maxr = max(0, min(w[0][1], self.height))
                minc = min(max(w[1][0], 0), self.width)
                maxc = max(0, min(w[1][1], self.width))
                win_shape += (maxr - minr, maxc - minc)
                window = ((minr, maxr), (minc, maxc))
        else:
            win_shape += self.shape

        dtype = 'uint8'

        if out is not None and out_shape is not None:
            raise ValueError("out and out_shape are exclusive")
        elif out_shape is not None:
            if len(out_shape) == 2:
                out_shape = (1,) + out_shape
            out = np.zeros(out_shape, 'uint8')

        if out is not None:
            if out.dtype != np.dtype(dtype):
                raise ValueError(
                    "the out array's dtype '%s' does not match '%s'"
                    % (out.dtype, dtype))
            if out.shape[0] != win_shape[0]:
                raise ValueError(
                    "'out' shape %s does not match window shape %s" %
                    (out.shape, win_shape))
        else:
            out = np.zeros(win_shape, 'uint8')


        # We can jump straight to _read() in some cases. We can ignore
        # the boundless flag if there's no given window.
        if not boundless or not window:
            out = self._read(indexes, out, window, dtype, masks=True)

        else:
            # Compute the overlap between the dataset and the boundless window.
            overlap = ((
                max(min(window[0][0], self.height), 0),
                max(min(window[0][1], self.height), 0)), (
                max(min(window[1][0], self.width), 0),
                max(min(window[1][1], self.width), 0)))

            if overlap != ((0, 0), (0, 0)):
                # Prepare a buffer.
                window_h, window_w = win_shape[-2:]
                overlap_h = overlap[0][1] - overlap[0][0]
                overlap_w = overlap[1][1] - overlap[1][0]
                scaling_h = float(out.shape[-2:][0])/window_h
                scaling_w = float(out.shape[-2:][1])/window_w
                buffer_shape = (int(overlap_h*scaling_h), int(overlap_w*scaling_w))
                data = np.empty(win_shape[:-2] + buffer_shape, 'uint8')
                data = self._read(indexes, data, overlap, dtype, masks=True)
            else:
                data = None

            if data is not None:
                # Determine where to put the data in the output window.
                data_h, data_w = data.shape[-2:]
                roff = 0
                coff = 0
                if window[0][0] < 0:
                    roff = int(window_h*scaling_h) - data_h
                if window[1][0] < 0:
                    coff = int(window_w*scaling_w) - data_w
                for dst, src in zip(
                        out if len(out.shape) == 3 else [out],
                        data if len(data.shape) == 3 else [data]):
                    dst[roff:roff+data_h, coff:coff+data_w] = src

        if return2d:
            out.shape = out.shape[1:]

        return out


    def _read(self, indexes, out, window, dtype, masks=False):
        """Read raster bands as a multidimensional array

        If `indexes` is a list, the result is a 3D array, but
        is a 2D array if it is a band index number.

        Optional `out` argument is a reference to an output array with the
        same dimensions and shape.

        See `read_band` for usage of the optional `window` argument.

        The return type will be either a regular NumPy array, or a masked
        NumPy array depending on the `masked` argument. The return type is
        forced if either `True` or `False`, but will be chosen if `None`.
        For `masked=None` (default), the array will be the same type as
        `out` (if used), or will be masked if any of the nodatavals are
        not `None`.
        """
        cdef int height, width, xoff, yoff, aix, bidx, indexes_count
        cdef int retval = 0

        if self._hds == NULL:
            raise ValueError("can't read closed raster file")

        # Prepare the IO window.
        if window:
            window = windows.evaluate(window, self.height, self.width)
            yoff = <int>window[0][0]
            xoff = <int>window[1][0]
            height = <int>window[0][1] - yoff
            width = <int>window[1][1] - xoff
        else:
            xoff = yoff = <int>0
            width = <int>self.width
            height = <int>self.height

        log.debug(
            "IO window xoff=%s yoff=%s width=%s height=%s",
            xoff, yoff, width, height)

        # Call io_multi* functions with C type args so that they
        # can release the GIL.
        indexes_arr = np.array(indexes, dtype=int)
        indexes_count = <int>indexes_arr.shape[0]
        gdt = dtypes.dtype_rev[dtype]

        
        if masks:
            # Warn if nodata attribute is shadowing an alpha band.
            if self.count == 4 and self.colorinterp(4) == ColorInterp.alpha:
                for flags in self.mask_flags:
                    if flags & MaskFlags.nodata:
                        warnings.warn(NodataShadowWarning())

            retval = io_multi_mask(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 1:
            retval = io_multi_ubyte(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 2:
            retval = io_multi_uint16(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 3:
            retval = io_multi_int16(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 4:
            retval = io_multi_uint32(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 5:
            retval = io_multi_int32(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 6:
            retval = io_multi_float32(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 7:
            retval = io_multi_float64(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 8:
            retval = io_multi_cint16(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 9:
            retval = io_multi_cint32(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 10:
            retval = io_multi_cfloat32(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)
        elif gdt == 11:
            retval = io_multi_cfloat64(
                            self._hds, 0, xoff, yoff, width, height,
                            out, indexes_arr, indexes_count)

        if retval in (1, 2, 3):
            raise IOError("Read or write failed")
        elif retval == 4:
            raise ValueError("NULL band")

        return out


    def dataset_mask(self, window=None, boundless=False):
        """Calculate the dataset's 2D mask. Derived from the individual band masks
        provided by read_masks().

        Parameters
        ----------
        window and boundless are passed directly to read_masks()

        Returns
        -------
        ndarray, shape=(self.height, self.width), dtype='uint8'
        0 = nodata, 255 = valid data

        The dataset mask is calculate based on the individual band masks according to
        the following logic, in order of precedence:

        1. If a .msk file, dataset-wide alpha or internal mask exists,
           it will be used as the dataset mask.
        2. If an 4-band RGBA with a shadow nodata value,
           band 4 will be used as the dataset mask.
        3. If a nodata value exists, use the binary OR (|) of the band masks
        4. If no nodata value exists, return a mask filled with 255

        Note that this differs from read_masks and GDAL RFC15
        in that it applies per-dataset, not per-band
        (see https://trac.osgeo.org/gdal/wiki/rfc15_nodatabitmask)
        """
        kwargs = {
            'window': window,
            'boundless': boundless}

        # GDAL found dataset-wide alpha band or mask
        # All band masks are equal so we can return the first
        if self.mask_flags[0] & MaskFlags.per_dataset:
            return self.read_masks(1, **kwargs)

        # use Alpha mask if available and looks like RGB, even if nodata is shadowing
        elif self.count == 4 and self.colorinterp(1) == ColorInterp.red:
            return self.read_masks(4, **kwargs)

        # Or use the binary OR intersection of all GDALGetMaskBands
        else:
            mask = self.read_masks(1, **kwargs)
            for i in range(1, self.count):
                mask = mask | self.read_masks(i, **kwargs)
            return mask

    def read_mask(self, indexes=None, out=None, window=None, boundless=False):
        """Read the mask band into an `out` array if provided,
        otherwise return a new array containing the dataset's
        valid data mask.

        The optional `window` argument takes a tuple like:

            ((row_start, row_stop), (col_start, col_stop))

        specifying a raster subset to write into.
        """
        cdef GDALRasterBandH band
        cdef GDALRasterBandH mask

        warnings.warn(
            "read_mask() is deprecated and will be removed by Rasterio 1.0. "
            "Please use read_masks() instead.",
            FutureWarning,
            stacklevel=2)

        band = self.band(1)
        mask = GDALGetMaskBand(band)
        if mask == NULL:
            return None

        if out is None:
            out_shape = (
                window
                and windows.shape(window, self.height, self.width)
                or self.shape)
            out = np.empty(out_shape, np.uint8)
        if window:
            window = windows.evaluate(window, self.height, self.width)
            yoff = window[0][0]
            xoff = window[1][0]
            height = window[0][1] - yoff
            width = window[1][1] - xoff
        else:
            xoff = yoff = 0
            width = self.width
            height = self.height

        io_ubyte(
            mask, 0, xoff, yoff, width, height, out)
        return out

    def sample(self, xy, indexes=None):
        """Get the values of a dataset at certain positions

        Values are from the nearest pixel. They are not interpolated.

        Parameters
        ----------
        xy : iterable, pairs of floats
            A sequence or generator of (x, y) pairs.

        indexes : list of ints or a single int, optional
            If `indexes` is a list, the result is a 3D array, but is
            a 2D array if it is a band index number.

        Returns
        -------
        Iterable, yielding dataset values for the specified `indexes`
        as an ndarray.
        """
        # In https://github.com/mapbox/rasterio/issues/378 a user has
        # found what looks to be a Cython generator bug. Until that can
        # be confirmed and fixed, the workaround is a pure Python
        # generator implemented in sample.py.
        return sample_gen(self, xy, indexes)


cdef class DatasetWriterBase(DatasetReaderBase):
    # Read-write access to raster data and metadata.

    def __init__(self, path, mode, driver=None, width=None, height=None,
                 count=None, crs=None, transform=None, dtype=None, nodata=None,
                 **kwargs):
        # Validate write mode arguments.
        if mode == 'w':
            if not isinstance(driver, string_types):
                raise TypeError("A driver name string is required.")
            try:
                width = int(width)
                height = int(height)
            except:
                raise TypeError("Integer width and height are required.")
            try:
                count = int(count)
            except:
                raise TypeError("Integer band count is required.")
            try:
                assert dtype is not None
                _ = np.dtype(dtype)
            except:
                raise TypeError("A valid dtype is required.")
        self.name = path
        self.mode = mode
        self.driver = driver
        self.width = width
        self.height = height
        self._count = count
        self._init_dtype = np.dtype(dtype).name
        self._init_nodata = nodata
        self._hds = NULL
        self._count = count
        self._crs = crs
        if transform is not None:
            self._transform = transform.to_gdal()
        self._closed = True
        self._dtypes = []
        self._nodatavals = []
        self._units = ()
        self._descriptions = ()
        self._options = kwargs.copy()

    def __repr__(self):
        return "<%s RasterUpdater name='%s' mode='%s'>" % (
            self.closed and 'closed' or 'open',
            self.name,
            self.mode)

    def start(self):
        cdef const char *drv_name = NULL
        cdef char **options = NULL
        cdef char *key_c = NULL
        cdef char *val_c = NULL
        cdef GDALDriverH drv = NULL
        cdef GDALRasterBandH band = NULL
        cdef int success

        # Parse the path to determine if there is scheme-specific
        # configuration to be done.
        path, archive, scheme = parse_path(self.name)
        path = vsi_path(path, archive, scheme)

        if scheme and scheme != 'file':
            raise TypeError(
                "VFS '{0}' datasets can not be created or updated.".format(
                    scheme))

        name_b = path.encode('utf-8')
        cdef const char *fname = name_b

        kwds = []

        if self.mode == 'w':

            # Delete existing file, create.
            if os.path.exists(path):
                os.unlink(path)

            driver_b = self.driver.encode('utf-8')
            drv_name = driver_b
            try:
                with CPLErrors() as cple:
                    drv = GDALGetDriverByName(drv_name)
                    cple.check()
            except Exception as err:
                raise DriverRegistrationError(str(err))

            # Find the equivalent GDAL data type or raise an exception
            # We've mapped numpy scalar types to GDAL types so see
            # if we can crosswalk those.
            if hasattr(self._init_dtype, 'type'):
                tp = self._init_dtype.type
                if tp not in dtypes.dtype_rev:
                    raise ValueError(
                        "Unsupported dtype: %s" % self._init_dtype)
                else:
                    gdal_dtype = dtypes.dtype_rev.get(tp)
            else:
                gdal_dtype = dtypes.dtype_rev.get(self._init_dtype)

            # Creation options
            for k, v in self._options.items():
                # Skip items that are definitely *not* valid driver options.
                if k.lower() in ['affine']:
                    continue
                kwds.append((k.lower(), v))
                k, v = k.upper(), str(v).upper()

                # Guard against block size that exceed image size.
                if k == 'BLOCKXSIZE' and int(v) > self.width:
                    raise ValueError("blockxsize exceeds raster width.")
                if k == 'BLOCKYSIZE' and int(v) > self.height:
                    raise ValueError("blockysize exceeds raster height.")

                key_b = k.encode('utf-8')
                val_b = v.encode('utf-8')
                key_c = key_b
                val_c = val_b
                options = CSLSetNameValue(options, key_c, val_c)
                log.debug(
                    "Option: %r\n",
                    (k, CSLFetchNameValue(options, key_c)))

            try:
                with CPLErrors() as cple:
                    self._hds = GDALCreate(
                        drv, fname, self.width, self.height, self._count,
                        gdal_dtype, options)
                    cple.check()
            except Exception as err:
                if options != NULL:
                    CSLDestroy(options)
                raise

            if self._init_nodata is not None:

                if not in_dtype_range(self._init_nodata, self._init_dtype):
                    raise ValueError(
                        "Given nodata value, %s, is beyond the valid "
                        "range of its data type, %s." % (
                            self._init_nodata, self._init_dtype))

                # Broadcast the nodata value to all bands.
                for i in range(self._count):
                    band = self.band(i + 1)
                    success = GDALSetRasterNoDataValue(band,
                                                       self._init_nodata)

            if self._transform:
                self.write_transform(self._transform)
            if self._crs:
                self.set_crs(self._crs)

        elif self.mode == 'r+':
            try:
                with CPLErrors() as cple:
                    self._hds = GDALOpen(fname, 1)
                    cple.check()
            except CPLE_OpenFailedError as err:
                raise RasterioIOError(str(err))

        drv = GDALGetDatasetDriver(self._hds)
        drv_name = GDALGetDriverShortName(drv)
        self.driver = drv_name.decode('utf-8')

        self._count = GDALGetRasterCount(self._hds)
        self.width = GDALGetRasterXSize(self._hds)
        self.height = GDALGetRasterYSize(self._hds)
        self.shape = (self.height, self.width)

        self._transform = self.read_transform()
        self._crs = self.read_crs()

        if options != NULL:
            CSLDestroy(options)

        # touch self.meta
        _ = self.meta

        self.update_tags(ns='rio_creation_kwds', **kwds)
        self._closed = False

    def set_crs(self, crs):
        """Writes a coordinate reference system to the dataset."""
        cdef char *proj_c = NULL
        cdef char *wkt = NULL
        cdef OGRSpatialReferenceH osr = NULL

        osr = OSRNewSpatialReference(NULL)
        if osr == NULL:
            raise ValueError("Null spatial reference")
        params = []

        log.debug("Input CRS: %r", crs)

        # Normally, we expect a CRS dict.
        if isinstance(crs, dict):
            crs = CRS(crs)
        if isinstance(crs, CRS):
            # EPSG is a special case.
            init = crs.get('init')
            if init:
                auth, val = init.split(':')
                if auth.upper() == 'EPSG':
                    OSRImportFromEPSG(osr, int(val))
            else:
                crs['wktext'] = True
                for k, v in crs.items():
                    if v is True or (k in ('no_defs', 'wktext') and v):
                        params.append("+%s" % k)
                    else:
                        params.append("+%s=%s" % (k, v))
                proj = " ".join(params)
                log.debug("PROJ.4 to be imported: %r", proj)
                proj_b = proj.encode('utf-8')
                proj_c = proj_b
                OSRImportFromProj4(osr, proj_c)
        # Fall back for CRS strings like "EPSG:3857."
        else:
            proj_b = crs.encode('utf-8')
            proj_c = proj_b
            OSRSetFromUserInput(osr, proj_c)

        # Fixup, export to WKT, and set the GDAL dataset's projection.
        OSRFixup(osr)
        OSRExportToWkt(osr, <char**>&wkt)
        wkt_b = wkt
        log.debug("Exported WKT: %s", wkt_b.decode('utf-8'))
        GDALSetProjection(self._hds, wkt)

        CPLFree(wkt)
        OSRDestroySpatialReference(osr)
        self._crs = crs
        log.debug("Self CRS: %r", self._crs)

    property crs:
        """A mapping of PROJ.4 coordinate reference system params.
        """

        def __get__(self):
            return self.get_crs()

        def __set__(self, value):
            self.set_crs(value)

    def write_transform(self, transform):
        if self._hds == NULL:
            raise ValueError("Can't read closed raster file")

        if [abs(v) for v in transform] == [0, 1, 0, 0, 0, 1]:
            warnings.warn(
                "Dataset uses default geotransform (Affine.identity). "
                "No transform will be written to the output by GDAL.",
                UserWarning
            )

        cdef double gt[6]
        for i in range(6):
            gt[i] = transform[i]
        err = GDALSetGeoTransform(self._hds, gt)
        if err:
            raise ValueError("transform not set: %s" % transform)
        self._transform = transform

    property transform:
        """An affine transformation that maps pixel row/column
        coordinates to coordinates in the specified crs. The affine
        transformation is represented by a six-element sequence.
        Reference system coordinates can be calculated by the
        following formula

        X = Item 0 + Column * Item 1 + Row * Item 2
        Y = Item 3 + Column * Item 4 + Row * Item 5

        See also this class's ul() method.
        """

        def __get__(self):
            return Affine.from_gdal(*self.get_transform())

        def __set__(self, value):
            self.write_transform(value.to_gdal())

    def set_nodatavals(self, vals):
        cdef GDALRasterBandH band = NULL
        cdef double nodataval
        cdef int success

        for i, val in zip(self.indexes, vals):
            band = self.band(i)
            nodataval = val
            success = GDALSetRasterNoDataValue(band, nodataval)
            if success:
                raise ValueError("Invalid nodata value: %r", val)
        self._nodatavals = vals

    property nodatavals:
        """A list by band of a dataset's nodata values.
        """

        def __get__(self):
            return self.get_nodatavals()

    property nodata:
        """The dataset's single nodata value."""

        def __get__(self):
            return self.nodatavals[0]

        def __set__(self, value):
            self.set_nodatavals([value for old_val in self.nodatavals])

    def write(self, src, indexes=None, window=None):
        """Write the src array into indexed bands of the dataset.

        If `indexes` is a list, the src must be a 3D array of
        matching shape. If an int, the src must be a 2D array.

        See `read()` for usage of the optional `window` argument.
        """
        cdef int height, width, xoff, yoff, indexes_count
        cdef int retval = 0

        if self._hds == NULL:
            raise ValueError("can't write to closed raster file")

        if indexes is None:
            indexes = self.indexes
        elif isinstance(indexes, int):
            indexes = [indexes]
            src = np.array([src])
        if len(src.shape) != 3 or src.shape[0] != len(indexes):
            raise ValueError(
                "Source shape is inconsistent with given indexes")

        check_dtypes = set()
        # Check each index before processing 3D array
        for bidx in indexes:
            if bidx not in self.indexes:
                raise IndexError("band index out of range")
            idx = self.indexes.index(bidx)
            check_dtypes.add(self.dtypes[idx])
        if len(check_dtypes) > 1:
            raise ValueError("more than one 'dtype' found")
        elif len(check_dtypes) == 0:
            dtype = self.dtypes[0]
        else:  # unique dtype; normal case
            dtype = check_dtypes.pop()

        if src is not None and src.dtype != dtype:
            raise ValueError(
                "the array's dtype '%s' does not match "
                "the file's dtype '%s'" % (src.dtype, dtype))

        # Require C-continguous arrays (see #108).
        src = np.require(src, dtype=dtype, requirements='C')

        # Prepare the IO window.
        if window:
            window = windows.evaluate(window, self.height, self.width)
            yoff = <int>window[0][0]
            xoff = <int>window[1][0]
            height = <int>window[0][1] - yoff
            width = <int>window[1][1] - xoff
        else:
            xoff = yoff = <int>0
            width = <int>self.width
            height = <int>self.height

        # Call io_multi* functions with C type args so that they
        # can release the GIL.
        indexes_arr = np.array(indexes, dtype=int)
        indexes_count = <int>indexes_arr.shape[0]
        gdt = dtypes.dtype_rev[dtype]
        if gdt == 1:
            retval = io_multi_ubyte(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)
        elif gdt == 2:
            retval = io_multi_uint16(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)
        elif gdt == 3:
            retval = io_multi_int16(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)
        elif gdt == 4:
            retval = io_multi_uint32(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)
        elif gdt == 5:
            retval = io_multi_int32(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)
        elif gdt == 6:
            retval = io_multi_float32(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)
        elif gdt == 7:
            retval = io_multi_float64(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)
        elif gdt == 8:
            retval = io_multi_cint16(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)
        elif gdt == 9:
            retval = io_multi_cint32(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)
        elif gdt == 10:
            retval = io_multi_cfloat32(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)
        elif gdt == 11:
            retval = io_multi_cfloat64(
                            self._hds, 1, xoff, yoff, width, height,
                            src, indexes_arr, indexes_count)

        if retval in (1, 2, 3):
            raise IOError("Read or write failed")
        elif retval == 4:
            raise ValueError("NULL band")

    def write_band(self, bidx, src, window=None):
        """Write the src array into the `bidx` band.

        Band indexes begin with 1: read_band(1) returns the first band.

        The optional `window` argument takes a tuple like:

            ((row_start, row_stop), (col_start, col_stop))

        specifying a raster subset to write into.
        """
        self.write(src, bidx, window=window)

    def update_tags(self, bidx=0, ns=None, **kwargs):
        """Updates the tags of a dataset or one of its bands.

        Tags are pairs of key and value strings. Tags belong to
        namespaces.  The standard namespaces are: default (None) and
        'IMAGE_STRUCTURE'.  Applications can create their own additional
        namespaces.

        The optional bidx argument can be used to select the dataset
        band. The optional ns argument can be used to select a namespace
        other than the default.
        """
        cdef char *key_c = NULL
        cdef char *value_c = NULL
        cdef GDALMajorObjectH hobj = NULL
        cdef const char *domain_c = NULL
        cdef char **papszStrList = NULL
        if bidx > 0:
            hobj = self.band(bidx)
        else:
            hobj = self._hds
        if ns:
            domain_b = ns.encode('utf-8')
            domain_c = domain_b
        else:
            domain_c = NULL

        papszStrList = CSLDuplicate(
            GDALGetMetadata(hobj, domain_c))

        for key, value in kwargs.items():
            key_b = text_type(key).encode('utf-8')
            value_b = text_type(value).encode('utf-8')
            key_c = key_b
            value_c = value_b
            papszStrList = CSLSetNameValue(
                    papszStrList, key_c, value_c)

        retval = GDALSetMetadata(hobj, papszStrList, domain_c)
        if papszStrList != NULL:
            CSLDestroy(papszStrList)

        if retval == 2:
            log.warn("Tags accepted but may not be persisted.")
        elif retval == 3:
            raise RuntimeError("Tag update failed.")

    def set_description(self, bidx, value):
        """Sets the description of a dataset band.

        Parameters
        ----------
        bidx : int
            Index of the band (starting with 1).

        value: string
            A description of the band.

        Returns
        -------
        None
        """
        cdef GDALRasterBandH hband = NULL

        hband = self.band(bidx)
        GDALSetDescription(hband, value.encode('utf-8'))
        # Invalidate cached descriptions.
        self._descriptions = ()

    def set_units(self, bidx, value):
        """Sets the units of a dataset band.

        Parameters
        ----------
        bidx : int
            Index of the band (starting with 1).

        value: string
            A label for the band's units such as 'meters' or 'degC'.
            See the Pint project for a suggested list of units.

        Returns
        -------
        None
        """
        cdef GDALRasterBandH hband = NULL

        hband = self.band(bidx)
        GDALSetRasterUnitType(hband, value.encode('utf-8'))
        # Invalidate cached units.
        self._units = ()

    def write_colormap(self, bidx, colormap):
        """Write a colormap for a band to the dataset."""
        cdef GDALRasterBandH hBand = NULL
        cdef GDALColorTableH hTable = NULL
        cdef GDALColorEntry color

        hBand = self.band(bidx)

        # RGB only for now. TODO: the other types.
        # GPI_Gray=0,  GPI_RGB=1, GPI_CMYK=2,     GPI_HLS=3
        hTable = GDALCreateColorTable(1)
        vals = range(256)

        for i, rgba in colormap.items():
            if len(rgba) == 4 and self.driver in ('GTiff'):
                warnings.warn(
                    "This format doesn't support alpha in colormap entries. "
                    "The value will be ignored.")

            elif len(rgba) == 3:
                rgba = tuple(rgba) + (255,)

            if i not in vals:
                log.warn("Invalid colormap key %d", i)
                continue

            color.c1, color.c2, color.c3, color.c4 = rgba
            GDALSetColorEntry(hTable, i, &color)

        # TODO: other color interpretations?
        GDALSetRasterColorInterpretation(hBand, 1)
        GDALSetRasterColorTable(hBand, hTable)
        GDALDestroyColorTable(hTable)

    def write_mask(self, mask_array, window=None):
        """Write the valid data mask src array into the dataset's band
        mask.

        The optional `window` argument takes a tuple like:

            ((row_start, row_stop), (col_start, col_stop))

        specifying a raster subset to write into.
        """
        cdef GDALRasterBandH band = NULL
        cdef GDALRasterBandH mask = NULL

        band = self.band(1)

        try:
            with CPLErrors() as cple:
                retval = GDALCreateMaskBand(band, 0x02)
                cple.check()
                mask = GDALGetMaskBand(band)
                cple.check()
                log.debug("Created mask band")
        except:
            raise RasterioIOError("Failed to get mask.")

        if window:
            window = windows.evaluate(window, self.height, self.width)
            yoff = window[0][0]
            xoff = window[1][0]
            height = window[0][1] - yoff
            width = window[1][1] - xoff
        else:
            xoff = yoff = 0
            width = self.width
            height = self.height

        if mask_array is True:
            GDALFillRaster(mask, 255, 0)
        elif mask_array is False:
            GDALFillRaster(mask, 0, 0)
        elif mask_array.dtype == np.bool:
            array = 255 * mask_array.astype(np.uint8)
            retval = io_ubyte(
                mask, 1, xoff, yoff, width, height, array)
        else:
            retval = io_ubyte(
                mask, 1, xoff, yoff, width, height, mask_array)

    def build_overviews(self, factors, resampling=Resampling.nearest):
        """Build overviews at one or more decimation factors for all
        bands of the dataset."""
        cdef int *factors_c = NULL
        cdef const char *resampling_c = NULL

        try:
            # GDALBuildOverviews() takes a string algo name, not a
            # Resampling enum member (like warping) and accepts only
            # a subset of the warp algorithms. 'NONE' is omitted below
            # (what does that even mean?) and so is 'AVERAGE_MAGPHASE'
            # (no corresponding member in the warp enum).
            resampling_map = {
                0: 'NEAREST',
                2: 'CUBIC',
                5: 'AVERAGE',
                6: 'MODE',
                7: 'GAUSS'}
            resampling_alg = resampling_map[Resampling(resampling.value)]
        except (KeyError, ValueError):
            raise ValueError(
                "resampling must be one of: {0}".format(", ".join(
                    ['Resampling.{0}'.format(Resampling(k).name) for k in
                     resampling_map.keys()])))

        # Allocate arrays.
        if factors:
            factors_c = <int *>CPLMalloc(len(factors)*sizeof(int))
            for i, factor in enumerate(factors):
                factors_c[i] = factor
            try:
                with CPLErrors() as cple:
                    resampling_b = resampling_alg.encode('utf-8')
                    resampling_c = resampling_b
                    err = GDALBuildOverviews(self._hds, resampling_c,
                        len(factors), factors_c, 0, NULL, NULL, NULL)
                    cple.check()
            finally:
                if factors_c != NULL:
                    CPLFree(factors_c)


cdef class InMemoryRaster:
    """
    Class that manages a single-band in memory GDAL raster dataset.  Data type
    is determined from the data type of the input numpy 2D array (image), and
    must be one of the data types supported by GDAL
    (see rasterio.dtypes.dtype_rev).  Data are populated at create time from
    the 2D array passed in.

    Use the 'with' pattern to instantiate this class for automatic closing
    of the memory dataset.

    This class includes attributes that are intended to be passed into GDAL
    functions:
    self.dataset
    self.band
    self.band_ids  (single element array with band ID of this dataset's band)
    self.transform (GDAL compatible transform array)

    This class is only intended for internal use within rasterio to support
    IO with GDAL.  Other memory based operations should use numpy arrays.
    """

    def __cinit__(self, image, transform=None, crs=None):
        """
        Create in-memory raster dataset, and populate its initial values with
        the values in image.

        :param image: 2D numpy array.  Must be of supported data type
        (see rasterio.dtypes.dtype_rev)
        :param transform: GDAL compatible transform array
        """

        self._image = image

        cdef int i = 0  # avoids Cython warning in for loop below
        cdef const char *srcwkt = NULL
        cdef OGRSpatialReferenceH osr = NULL
        cdef GDALDriverH mdriver = NULL

        if len(image.shape) == 3:
            count, height, width = image.shape
        elif len(image.shape) == 2:
            count = 1
            height, width = image.shape

        self.band_ids[0] = 1

        with CPLErrors() as cple:
            memdriver = GDALGetDriverByName("MEM")
            cple.check()
            datasetname = str(uuid.uuid4()).encode('utf-8')
            self._hds = GDALCreate(
                memdriver, <const char *>datasetname, width, height, count,
                <GDALDataType>dtypes.dtype_rev[image.dtype.name], NULL)
            cple.check()

        if transform is not None:
            for i in range(6):
                self.transform[i] = transform[i]
            err = GDALSetGeoTransform(self._hds, self.transform)
            if err:
                raise ValueError("transform not set: %s" % transform)

        # Set projection if specified (for use with
        # GDALSuggestedWarpOutput2()).
        if crs:
            osr = _osr_from_crs(crs)
            OSRExportToWkt(osr, <char**>&srcwkt)
            GDALSetProjection(self._hds, srcwkt)
            log.debug("Set CRS on temp source dataset: %s", srcwkt)
            CPLFree(<void *>srcwkt)
            OSRDestroySpatialReference(osr)

        self.write(image)

    def __enter__(self):
        return self

    def __exit__(self, *args, **kwargs):
        self.close()

    cdef GDALDatasetH handle(self) except NULL:
        """Return the object's GDAL dataset handle"""
        return self._hds

    cdef GDALRasterBandH band(self, int bidx) except NULL:
        """Return a GDAL raster band handle"""
        cdef GDALRasterBandH band = NULL

        try:
            with CPLErrors() as cple:
                band = GDALGetRasterBand(self._hds, bidx)
                cple.check()
        except CPLE_IllegalArgError as exc:
            raise IndexError(str(exc))
        if band == NULL:
            raise ValueError("NULL band")

        return band

    def close(self):
        if self._hds != NULL:
            GDALClose(self._hds)
            self._hds = NULL

    def read(self):
        io_auto(self._image, self.band(1), False)
        return self._image

    def write(self, image):
        io_auto(image, self.band(1), True)


cdef class BufferedDatasetWriterBase(DatasetWriterBase):

    def __repr__(self):
        return "<%s IndirectRasterUpdater name='%s' mode='%s'>" % (
            self.closed and 'closed' or 'open',
            self.name,
            self.mode)

    def start(self):
        cdef const char *drv_name = NULL
        cdef GDALDriverH drv = NULL
        cdef GDALDriverH memdrv = NULL
        cdef GDALRasterBandH band = NULL
        cdef GDALDatasetH temp = NULL
        cdef int success

        # Parse the path to determine if there is scheme-specific
        # configuration to be done.
        path = vsi_path(*parse_path(self.name))
        name_b = path.encode('utf-8')
        cdef const char *fname = name_b

        memdrv = GDALGetDriverByName("MEM")

        if self.mode == 'w':
            # Find the equivalent GDAL data type or raise an exception
            # We've mapped numpy scalar types to GDAL types so see
            # if we can crosswalk those.
            if hasattr(self._init_dtype, 'type'):
                tp = self._init_dtype.type
                if tp not in dtypes.dtype_rev:
                    raise ValueError(
                        "Unsupported dtype: %s" % self._init_dtype)
                else:
                    gdal_dtype = dtypes.dtype_rev.get(tp)
            else:
                gdal_dtype = dtypes.dtype_rev.get(self._init_dtype)

            try:
                with CPLErrors() as cple:
                    self._hds = GDALCreate(
                        memdrv, "temp", self.width, self.height, self._count,
                        gdal_dtype, NULL)
                    cple.check()
            except:
                raise

            if self._init_nodata is not None:
                for i in range(self._count):
                    band = self.band(i+1)
                    success = GDALSetRasterNoDataValue(
                        band, self._init_nodata)
            if self._transform:
                self.write_transform(self._transform)
            if self._crs:
                self.set_crs(self._crs)

        elif self.mode == 'r+':
            try:
                with CPLErrors() as cple:
                    temp = GDALOpen(fname, 0)
                    cple.check()
            except Exception as exc:
                raise RasterioIOError(str(exc))

            try:
                with CPLErrors() as cple:
                    self._hds = GDALCreateCopy(
                        memdrv, "temp", temp, 1, NULL, NULL, NULL)
                    cple.check()
            except:
                raise

            drv = GDALGetDatasetDriver(temp)
            self.driver = get_driver_name(drv)
            GDALClose(temp)

        self._count = GDALGetRasterCount(self._hds)
        self.width = GDALGetRasterXSize(self._hds)
        self.height = GDALGetRasterYSize(self._hds)
        self.shape = (self.height, self.width)

        self._transform = self.read_transform()
        self._crs = self.read_crs()

        # touch self.meta
        _ = self.meta

        self._closed = False

    def close(self):
        cdef const char *drv_name = NULL
        cdef char **options = NULL
        cdef char *key_c = NULL
        cdef char *val_c = NULL
        cdef GDALDriverH drv = NULL
        cdef GDALDatasetH temp = NULL
        cdef int success
        name_b = self.name.encode('utf-8')
        cdef const char *fname = name_b

        # Delete existing file, create.
        if os.path.exists(self.name):
            os.unlink(self.name)

        driver_b = self.driver.encode('utf-8')
        drv_name = driver_b
        drv = GDALGetDriverByName(drv_name)
        if drv == NULL:
            raise ValueError("NULL driver for %s", self.driver)

        kwds = []
        # Creation options
        for k, v in self._options.items():
            # Skip items that are definitely *not* valid driver options.
            if k.lower() in ['affine']:
                continue
            kwds.append((k.lower(), v))
            k, v = k.upper(), str(v).upper()
            key_b = k.encode('utf-8')
            val_b = v.encode('utf-8')
            key_c = key_b
            val_c = val_b
            options = CSLSetNameValue(options, key_c, val_c)
            log.debug(
                "Option: %r\n",
                (k, CSLFetchNameValue(options, key_c)))

        #self.update_tags(ns='rio_creation_kwds', **kwds)
        try:
            with CPLErrors() as cple:
                temp = GDALCreateCopy(
                    drv, fname, self._hds, 1, options, NULL, NULL)
                cple.check()
        except:
            raise
        finally:
            if options != NULL:
                CSLDestroy(options)
            if temp != NULL:
                GDALClose(temp)


def virtual_file_to_buffer(filename):
    """Read content of a virtual file into a Python bytes buffer."""
    cdef unsigned char *buff = NULL
    cdef const char *cfilename = NULL
    cdef vsi_l_offset buff_len = 0

    filename_b = filename if not isinstance(filename, string_types) else filename.encode('utf-8')
    cfilename = filename_b

    try:
        with CPLErrors() as cple:
            buff = VSIGetMemFileBuffer(cfilename, &buff_len, 0)
            cple.check()
    except:
        raise

    n = buff_len
    log.debug("Buffer length: %d bytes", n)
    cdef np.uint8_t[:] buff_view = <np.uint8_t[:n]>buff
    return buff_view
