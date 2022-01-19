#pragma once
/**
 * Created by Bogdan, Dec 16, 2021
 * based off of https://github.com/felixpatzelt/colorednoise/blob/master/colorednoise.py
 */

#include <cufft.h>
#include <curand.h>
#include <Eigen/Dense>

#include <mppi/utils/gpu_err_chk.cuh>

#include <algorithm>
#include <iostream>
#include <vector>

__global__ void configureFrequencyNoise(cufftComplex* noise, float* variance, int num_samples, int control_dim,
                                        int num_freq)
{
  int sample_index = blockDim.x * blockIdx.x + threadIdx.x;
  int freq_index = blockDim.y * blockIdx.y + threadIdx.y;
  int control_index = blockDim.z * blockIdx.z + threadIdx.z;

  if (sample_index < num_samples && freq_index < num_freq && control_index < control_dim)
  {
    int noise_index = (sample_index * control_dim + control_index) * num_freq + freq_index;
    int variance_index = control_index * num_freq + freq_index;
    noise[noise_index].x *= variance[variance_index];
    if (freq_index == 0)
    {
      noise[noise_index].y = 0;
    }
    else if (num_freq % 2 == 1 && freq_index == num_freq - 1)
    {
      noise[noise_index].y = 0;
    }
    else
    {
      noise[noise_index].y *= variance[variance_index];
    }
  }
}

__global__ void rearrangeNoise(float* input, float* output, float* variance, int num_trajectories, int num_timesteps,
                               int control_dim)
{
  int sample_index = blockIdx.x * blockDim.x + threadIdx.x;
  int time_index = blockIdx.y * blockDim.y + threadIdx.y;
  int control_index = blockIdx.z * blockDim.z + threadIdx.z;
  if (sample_index < num_trajectories && time_index < num_timesteps && control_index < control_dim)
  {  // cuFFT does not normalize inverse transforms so a division by the num_timesteps is required
    output[(sample_index * num_timesteps + time_index) * control_dim + control_index] =
        input[(sample_index * control_dim + control_index) * num_timesteps + time_index] /
        (variance[control_index] * num_timesteps);
    // printf("ROLLOUT %d CONTROL %d TIME %d: in %f out: %f\n", sample_index, control_index, time_index,
    //     input[(sample_index * control_dim + control_index) * num_timesteps + time_index],
    //     output[(sample_index * num_timesteps + time_index) * control_dim + control_index]);
  }
}

void fftfreq(const int num_samples, std::vector<float>& result, const float spacing = 1)
{
  // result is of size floor(n/2) + 1
  int result_size = num_samples / 2 + 1;
  result.clear();
  result.resize(result_size);
  for (int i = 0; i < result_size; i++)
  {
    result[i] = i / (spacing * num_samples);
  }
}

void powerlaw_psd_gaussian(std::vector<float>& exponents, int num_timesteps, int num_trajectories,
                           float* control_noise_d, curandGenerator_t& gen, cudaStream_t stream = 0, float fmin = 0.0)
{
  const int BLOCKSIZE_X = 32;
  const int BLOCKSIZE_Y = 32;
  const int BLOCKSIZE_Z = 1;
  int control_dim = exponents.size();

  std::vector<float> sample_freq;
  fftfreq(num_timesteps, sample_freq);
  float cutoff_freq = fmaxf(fmin, 1.0 / num_timesteps);
  int freq_size = sample_freq.size();

  int smaller_index = 0;
  Eigen::MatrixXf sample_freqs(freq_size, control_dim);

  // Adjust the weighting of each frequency by the exponents
  for (int i = 0; i < freq_size; i++)
  {
    if (sample_freq[i] < cutoff_freq)
    {
      smaller_index++;
    }
    else if (smaller_index < freq_size)
    {
      for (int j = 0; j < smaller_index; j++)
      {
        sample_freq[j] = sample_freq[smaller_index];
        for (int k = 0; k < control_dim; k++)
        {
          sample_freqs(j, k) = powf(sample_freq[smaller_index], -exponents[k] / 2.0);
        }
      }
    }
    for (int j = 0; j < control_dim; j++)
    {
      sample_freqs(i, j) = powf(sample_freq[i], -exponents[j] / 2.0);
    }
  }

  // Calculate variance
  float sigma[control_dim] = { 0 };
  for (int i = 0; i < control_dim; i++)
  {
    for (int j = 1; j < freq_size - 1; j++)
    {
      sigma[i] += powf(sample_freqs(j, i), 2);
    }
    // std::for_each(sample_freq.begin() + 1, sample_freq.end() - 1, [&sigma, &i](float j) { sigma[i] += powf(j, 2); });
    sigma[i] += powf(sample_freqs(freq_size - 1, i) * ((1.0 + (num_timesteps % 2)) / 2.0), 2);
    sigma[i] = 2 * sqrt(sigma[i]) / num_timesteps;
  }

  // Sample the noise in frequency domain and reutrn to time domain
  cufftHandle plan;
  const int batch = num_trajectories * control_dim;
  // Need 2 * (num_timesteps / 2 + 1) * batch of randomly sampled values
  // float* samples_in_freq_d;
  float* sigma_d;
  float* noise_in_time_d;
  cufftComplex* samples_in_freq_complex_d;
  float* freq_coeffs_d;
  // HANDLE_ERROR(cudaMalloc((void**)&samples_in_freq_d, sizeof(float) * 2 * batch * freq_size));
  // HANDLE_ERROR(cudaMalloc((void**)&samples_in_freq_d, sizeof(float) * 2 * batch * num_timesteps));
  HANDLE_ERROR(cudaMalloc((void**)&freq_coeffs_d, sizeof(float) * freq_size * control_dim));
  HANDLE_ERROR(cudaMalloc((void**)&samples_in_freq_complex_d, sizeof(cufftComplex) * batch * freq_size));
  HANDLE_ERROR(cudaMalloc((void**)&noise_in_time_d, sizeof(float) * batch * num_timesteps));
  HANDLE_ERROR(cudaMalloc((void**)&sigma_d, sizeof(float) * control_dim));
  // curandSetStream(gen, stream);
  HANDLE_CURAND_ERROR(curandGenerateNormal(gen, (float*)samples_in_freq_complex_d, 2 * batch * freq_size, 0.0, 1.0));
  HANDLE_ERROR(cudaMemcpyAsync(freq_coeffs_d, sample_freqs.data(), sizeof(float) * freq_size * control_dim,
                               cudaMemcpyHostToDevice, stream));
  HANDLE_ERROR(cudaMemcpyAsync(sigma_d, sigma, sizeof(float) * control_dim, cudaMemcpyHostToDevice, stream));
  const int variance_grid_x = (num_trajectories - 1) / BLOCKSIZE_X + 1;
  const int variance_grid_y = (freq_size - 1) / BLOCKSIZE_Y + 1;
  const int variance_grid_z = (control_dim - 1) / BLOCKSIZE_Z + 1;
  dim3 grid(variance_grid_x, variance_grid_y, variance_grid_z);
  dim3 block(BLOCKSIZE_X, BLOCKSIZE_Y, BLOCKSIZE_Z);
  // configureFrequencyNoise<<<grid, block, 0, stream>>>((cuComplex*) samples_in_freq_d, freq_coeffs_d, freq_size,
  // batch);
  configureFrequencyNoise<<<grid, block, 0, stream>>>(samples_in_freq_complex_d, freq_coeffs_d, num_trajectories,
                                                      control_dim, freq_size);
  HANDLE_ERROR(cudaGetLastError());
  HANDLE_CUFFT_ERROR(cufftPlan1d(&plan, num_timesteps, CUFFT_C2R, batch));
  HANDLE_CUFFT_ERROR(cufftSetStream(plan, stream));
  // freq_data needs to be batch number of num_timesteps/2 + 1 cuComplex values
  // time_data needs to be batch * num_timesteps floats
  HANDLE_CUFFT_ERROR(cufftExecC2R(plan, samples_in_freq_complex_d, noise_in_time_d));
  const int reorder_grid_x = (num_trajectories - 1) / BLOCKSIZE_X + 1;
  const int reorder_grid_y = (num_timesteps - 1) / BLOCKSIZE_Y + 1;
  const int reorder_grid_z = (control_dim - 1) / BLOCKSIZE_Z + 1;
  dim3 reorder_grid(reorder_grid_x, reorder_grid_y, reorder_grid_z);
  dim3 reorder_block(BLOCKSIZE_X, BLOCKSIZE_Y, BLOCKSIZE_Z);
  // std::cout << "Grid: " << reorder_grid.x << ", " << reorder_grid.y << ", " << reorder_grid.z << std::endl;
  // std::cout << "Block: " << reorder_block.x << ", " << reorder_block.y << ", " << reorder_block.z << std::endl;
  rearrangeNoise<<<reorder_grid, reorder_block, 0, stream>>>(noise_in_time_d, control_noise_d, sigma_d,
                                                             num_trajectories, num_timesteps, control_dim);
  HANDLE_ERROR(cudaGetLastError());
  HANDLE_ERROR(cudaStreamSynchronize(stream));
  HANDLE_CUFFT_ERROR(cufftDestroy(plan));
  // HANDLE_ERROR(cudaFree(samples_in_freq_d));
  HANDLE_ERROR(cudaFree(freq_coeffs_d));
  HANDLE_ERROR(cudaFree(sigma_d));
  HANDLE_ERROR(cudaFree(samples_in_freq_complex_d));
  HANDLE_ERROR(cudaFree(noise_in_time_d));
}