//
// Created by jason on 1/5/22.
//

#ifndef MPPIGENERIC_TEXTURE_HELPER_CUH
#define MPPIGENERIC_TEXTURE_HELPER_CUH

#include <mppi/utils/managed.cuh>

template <class DATA_T>
struct TextureParams
{
  cudaExtent extent;

  cudaArray* array_d = nullptr;
  cudaTextureObject_t tex_d = 0;
  cudaChannelFormatDesc channelDesc;
  cudaResourceDesc resDesc;
  cudaTextureDesc texDesc;

  float3 origin;
  float3 rotations[3];
  float3 resolution;

  bool column_major = false;
  bool use = false;        // indicates that the texture is to be used or not, separate from allocation
  bool allocated = false;  // indicates that the texture has been allocated on the GPU
  bool update_data = false;
  bool update_mem = false;  // indicates the GPU structure should be updated at the next convenient time
  bool update_params = false;

  TextureParams()
  {
    resDesc.resType = cudaResourceTypeArray;
    channelDesc = cudaCreateChannelDesc<DATA_T>();

    // clamp
    memset(&texDesc, 0, sizeof(texDesc));
    texDesc.addressMode[0] = cudaAddressModeClamp;
    texDesc.addressMode[1] = cudaAddressModeClamp;
    texDesc.addressMode[2] = cudaAddressModeClamp;
    texDesc.filterMode = cudaFilterModeLinear;
    texDesc.readMode = cudaReadModeElementType;
    texDesc.normalizedCoords = 1;

    origin = make_float3(0.0, 0.0, 0.0);
    rotations[0] = make_float3(1, 0, 0);
    rotations[1] = make_float3(0, 1, 0);
    rotations[2] = make_float3(0, 0, 1);
    resolution = make_float3(1, 1, 1);
  }
};

template <class TEX_T, class DATA_T>
class TextureHelper : public Managed
{
protected:
  TextureHelper(int number, cudaStream_t stream = 0);

public:
  virtual ~TextureHelper();

  void GPUSetup();

  static void freeCudaMem(TextureParams<DATA_T>& texture);
  virtual void freeCudaMem();

  /**
   * helper method to deallocate the index before allocating new ones
   */
  virtual void allocateCudaTexture(int index);
  /**
   * helper method to create a cuda texture
   * @param index
   */
  virtual void createCudaTexture(int index, bool sync = true);

  /**
   * Copies texture information to the GPU version of the object
   */
  virtual void copyToDevice(bool synchronize = false);

  /**
   *
   */
  virtual void addNewTexture(const cudaExtent& extent);

  __host__ __device__ void worldPoseToMapPose(const int index, const float3& input, float3& output);
  __host__ __device__ void mapPoseToTexCoord(const int index, const float3& input, float3& output);
  __host__ __device__ void worldPoseToTexCoord(const int index, const float3& input, float3& output);
  __device__ DATA_T queryTextureAtWorldPose(const int index, const float3& input);
  __device__ DATA_T queryTextureAtMapPose(int index, const float3& input);

  virtual void updateOrigin(int index, float3 new_origin);
  virtual void updateRotation(int index, std::array<float3, 3>& new_rotation);
  virtual void updateResolution(int index, float resolution);
  virtual void updateResolution(int index, float3 resolution);
  virtual bool setExtent(int index, cudaExtent& extent);
  virtual void copyDataToGPU(int index, bool sync = false) = 0;
  virtual void copyParamsToGPU(int index, bool sync = false);
  virtual void setColumnMajor(int index, bool val)
  {
    this->textures_[index].column_major = val;
  }
  virtual void enableTexture(int index)
  {
    this->textures_[index].update_params = true;
    this->textures_[index].use = true;
  }
  virtual void disableTexture(int index)
  {
    this->textures_[index].update_params = true;
    this->textures_[index].use = false;
  }
  __device__ __host__ bool checkTextureUse(int index)
  {
    return this->textures_d_[index].use;
  }

  void updateAddressMode(int index, cudaTextureAddressMode mode);
  void updateAddressMode(int index, int layer, cudaTextureAddressMode mode);

  std::vector<TextureParams<float4>> getTextures()
  {
    return textures_;
  }

  TEX_T* ptr_d_ = nullptr;

protected:
  std::vector<TextureParams<DATA_T>> textures_;

  // helper, on CPU points to vector data (textures_.data()), on GPU points to device copy (params_d_ variable)
  TextureParams<DATA_T>* textures_d_ = nullptr;

  // device pointer to the parameters malloced memory
  TextureParams<DATA_T>* params_d_;
};

#if __CUDACC__
#include "texture_helper.cu"
#endif

#endif  // MPPIGENERIC_TEXTURE_HELPER_CUH