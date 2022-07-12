#include <mppi/controllers/ColoredMPPI/colored_mppi_controller.cuh>
#include <mppi/core/mppi_common.cuh>
#include <algorithm>
#include <iostream>
#include <mppi/sampling_distributions/colored_noise/colored_noise.cuh>

#define ColoredMPPI ColoredMPPIController<DYN_T, COST_T, FB_T, MAX_TIMESTEPS, NUM_ROLLOUTS, BDIM_X, BDIM_Y, PARAMS_T>

template <class DYN_T, class COST_T, class FB_T, int MAX_TIMESTEPS, int NUM_ROLLOUTS, int BDIM_X, int BDIM_Y,
          class PARAMS_T>
ColoredMPPI::ColoredMPPIController(DYN_T* model, COST_T* cost, FB_T* fb_controller, float dt, int max_iter,
                                   float lambda, float alpha, const Eigen::Ref<const control_array>& control_std_dev,
                                   int num_timesteps, const Eigen::Ref<const control_trajectory>& init_control_traj,
                                   cudaStream_t stream)
  : PARENT_CLASS(model, cost, fb_controller, dt, max_iter, lambda, alpha, control_std_dev, num_timesteps,
                 init_control_traj, stream)
{
  // Allocate CUDA memory for the controller
  allocateCUDAMemory();
  std::vector<float> tmp_vec(DYN_T::CONTROL_DIM, 0.0);
  this->params_.colored_noise_exponents_ = std::move(tmp_vec);

  // Copy the noise std_dev to the device
  this->copyControlStdDevToDevice();
}

template <class DYN_T, class COST_T, class FB_T, int MAX_TIMESTEPS, int NUM_ROLLOUTS, int BDIM_X, int BDIM_Y,
          class PARAMS_T>
ColoredMPPI::ColoredMPPIController(DYN_T* model, COST_T* cost, FB_T* fb_controller, PARAMS_T& params,
                                   cudaStream_t stream)
  : PARENT_CLASS(model, cost, fb_controller, params, stream)
{
  // Allocate CUDA memory for the controller
  allocateCUDAMemory();
  if (this->getColoredNoiseExponentsLValue().size() == 0)
  {
    std::vector<float> tmp_vec(DYN_T::CONTROL_DIM, 0.0);
    getColoredNoiseExponentsLValue() = std::move(tmp_vec);
  }

  // Copy the noise std_dev to the device
  this->copyControlStdDevToDevice();
}

template <class DYN_T, class COST_T, class FB_T, int MAX_TIMESTEPS, int NUM_ROLLOUTS, int BDIM_X, int BDIM_Y,
          class PARAMS_T>
ColoredMPPI::~ColoredMPPIController()
{
  // all implemented in standard controller
}

template <class DYN_T, class COST_T, class FB_T, int MAX_TIMESTEPS, int NUM_ROLLOUTS, int BDIM_X, int BDIM_Y,
          class PARAMS_T>
void ColoredMPPI::computeControl(const Eigen::Ref<const state_array>& state, int optimization_stride)
{
  this->free_energy_statistics_.real_sys.previousBaseline = this->getBaselineCost();
  state_array local_state = state;
  for (int i = 0; i < DYN_T::STATE_DIM; i++)
  {
    float diff = fabsf(this->state_.col(leash_jump_)[i] - state[i]);
    if (getStateLeashLength(i) < diff)
    {
      float leash_dir =
          fminf(fmaxf(this->state_.col(leash_jump_)[i] - state[i], -getStateLeashLength(i)), getStateLeashLength(i));
      local_state[i] = state[i] + leash_dir;
    }
    else
    {
      local_state[i] = this->state_.col(leash_jump_)[i];
    }
  }

  // Send the initial condition to the device
  HANDLE_ERROR(cudaMemcpyAsync(this->initial_state_d_, local_state.data(), DYN_T::STATE_DIM * sizeof(float),
                               cudaMemcpyHostToDevice, this->stream_));

  float baseline_prev = 1e8;

  for (int opt_iter = 0; opt_iter < this->getNumIters(); opt_iter++)
  {
    // Send the nominal control to the device
    this->copyNominalControlToDevice(false);

    // Generate noise data
    powerlaw_psd_gaussian(getColoredNoiseExponentsLValue(), this->getNumTimesteps(), NUM_ROLLOUTS,
                          this->control_noise_d_, this->gen_, this->stream_);
    // curandGenerateNormal(this->gen_, this->control_noise_d_, NUM_ROLLOUTS * this->getNumTimesteps() *
    // DYN_T::CONTROL_DIM,
    //                      0.0, 1.0);
    /*
    std::vector<float> noise = this->getSampledNoise();
    float mean = 0;
    for(int k = 0; k < noise.size(); k++) {
      mean += (noise[k]/noise.size());
    }

    float std_dev = 0;
    for(int k = 0; k < noise.size(); k++) {
      std_dev += powf(noise[k] - mean, 2);
    }
    std_dev = sqrt(std_dev/noise.size());
    printf("CPU 1 side N(%f, %f)\n", mean, std_dev);
     */

    // Launch the rollout kernel
    mppi_common::launchRolloutKernel<DYN_T, COST_T, NUM_ROLLOUTS, BDIM_X, BDIM_Y>(
        this->model_->model_d_, this->cost_->cost_d_, this->getDt(), this->getNumTimesteps(), optimization_stride,
        this->getLambda(), this->getAlpha(), this->initial_state_d_, this->control_d_, this->control_noise_d_,
        this->control_std_dev_d_, this->trajectory_costs_d_, this->stream_, false);
    /*
    noise = this->getSampledNoise();
    mean = 0;
    for(int k = 0; k < noise.size(); k++) {
      mean += (noise[k]/noise.size());
    }

    std_dev = 0;
    for(int k = 0; k < noise.size(); k++) {
      std_dev += powf(noise[k] - mean, 2);
    }
    std_dev = sqrt(std_dev/noise.size());
    printf("CPU 2 side N(%f, %f)\n", mean, std_dev);
     */

    // Copy the costs back to the host
    HANDLE_ERROR(cudaMemcpyAsync(this->trajectory_costs_.data(), this->trajectory_costs_d_,
                                 NUM_ROLLOUTS * sizeof(float), cudaMemcpyDeviceToHost, this->stream_));
    HANDLE_ERROR(cudaStreamSynchronize(this->stream_));

    this->setBaseline(mppi_common::computeBaselineCost(this->trajectory_costs_.data(), NUM_ROLLOUTS));

    if (this->getBaselineCost() > baseline_prev + 1)
    {
      // TODO handle printing
      if (this->debug_)
      {
        std::cout << "Previous Baseline: " << baseline_prev << std::endl;
        std::cout << "         Baseline: " << this->getBaselineCost() << std::endl;
      }
    }

    baseline_prev = this->getBaselineCost();

    // Launch the norm exponential kernel
    if (getGamma() == 0 || getRExp() == 0)
    {
      mppi_common::launchNormExpKernel(NUM_ROLLOUTS, BDIM_X, this->trajectory_costs_d_, 1.0 / this->getLambda(),
                                       this->getBaselineCost(), this->stream_, false);
    }
    else
    {
      mppi_common::launchTsallisKernel(NUM_ROLLOUTS, BDIM_X, this->trajectory_costs_d_, getGamma(), getRExp(),
                                       this->getBaselineCost(), this->stream_, false);
    }
    HANDLE_ERROR(cudaMemcpyAsync(this->trajectory_costs_.data(), this->trajectory_costs_d_,
                                 NUM_ROLLOUTS * sizeof(float), cudaMemcpyDeviceToHost, this->stream_));
    HANDLE_ERROR(cudaStreamSynchronize(this->stream_));

    // Compute the normalizer
    this->setNormalizer(mppi_common::computeNormalizer(this->trajectory_costs_.data(), NUM_ROLLOUTS));

    mppi_common::computeFreeEnergy(this->free_energy_statistics_.real_sys.freeEnergyMean,
                                   this->free_energy_statistics_.real_sys.freeEnergyVariance,
                                   this->free_energy_statistics_.real_sys.freeEnergyModifiedVariance,
                                   this->trajectory_costs_.data(), NUM_ROLLOUTS, this->getBaselineCost(),
                                   this->getLambda());

    // Compute the cost weighted average //TODO SUM_STRIDE is BDIM_X, but should it be its own parameter?
    mppi_common::launchWeightedReductionKernel<DYN_T, NUM_ROLLOUTS, BDIM_X>(
        this->trajectory_costs_d_, this->control_noise_d_, this->control_d_, this->getNormalizerCost(),
        this->getNumTimesteps(), this->stream_, false);

    /*
    noise = this->getSampledNoise();
    mean = 0;
    for(int k = 0; k < noise.size(); k++) {
      mean += (noise[k]/noise.size());
    }

    std_dev = 0;
    for(int k = 0; k < noise.size(); k++) {
      std_dev += powf(noise[k] - mean, 2);
    }
    std_dev = sqrt(std_dev/noise.size());
    printf("CPU 3 side N(%f, %f)\n", mean, std_dev);
     */

    // Transfer the new control to the host
    HANDLE_ERROR(cudaMemcpyAsync(this->control_.data(), this->control_d_,
                                 sizeof(float) * this->getNumTimesteps() * DYN_T::CONTROL_DIM, cudaMemcpyDeviceToHost,
                                 this->stream_));
    HANDLE_ERROR(cudaStreamSynchronize(this->stream_));
  }

  this->free_energy_statistics_.real_sys.normalizerPercent = this->getNormalizerCost() / NUM_ROLLOUTS;
  this->free_energy_statistics_.real_sys.increase =
      this->getBaselineCost() - this->free_energy_statistics_.real_sys.previousBaseline;
  smoothControlTrajectory();
  computeStateTrajectory(local_state);
  state_array zero_state = state_array::Zero();
  for (int i = 0; i < this->getNumTimesteps(); i++)
  {
    // this->model_->enforceConstraints(zero_state, this->control_.col(i));
    this->control_.col(i)[1] =
        fminf(fmaxf(this->control_.col(i)[1], this->model_->control_rngs_[1].x), this->model_->control_rngs_[1].y);
  }

  // Copy back sampled trajectories
  this->copySampledControlFromDevice(false);
  this->copyTopControlFromDevice(true);
}

template <class DYN_T, class COST_T, class FB_T, int MAX_TIMESTEPS, int NUM_ROLLOUTS, int BDIM_X, int BDIM_Y,
          class PARAMS_T>
void ColoredMPPI::allocateCUDAMemory()
{
  PARENT_CLASS::allocateCUDAMemoryHelper();
}

template <class DYN_T, class COST_T, class FB_T, int MAX_TIMESTEPS, int NUM_ROLLOUTS, int BDIM_X, int BDIM_Y,
          class PARAMS_T>
void ColoredMPPI::computeStateTrajectory(const Eigen::Ref<const state_array>& x0)
{
  this->computeStateTrajectoryHelper(this->state_, x0, this->control_);
}

template <class DYN_T, class COST_T, class FB_T, int MAX_TIMESTEPS, int NUM_ROLLOUTS, int BDIM_X, int BDIM_Y,
          class PARAMS_T>
void ColoredMPPI::slideControlSequence(int steps)
{
  // TODO does the logic of handling control history reasonable?
  leash_jump_ = steps;
  // Save the control history
  this->saveControlHistoryHelper(steps, this->control_, this->control_history_);

  this->slideControlSequenceHelper(steps, this->control_);
}

template <class DYN_T, class COST_T, class FB_T, int MAX_TIMESTEPS, int NUM_ROLLOUTS, int BDIM_X, int BDIM_Y,
          class PARAMS_T>
void ColoredMPPI::smoothControlTrajectory()
{
  this->smoothControlTrajectoryHelper(this->control_, this->control_history_);
}

template <class DYN_T, class COST_T, class FB_T, int MAX_TIMESTEPS, int NUM_ROLLOUTS, int BDIM_X, int BDIM_Y,
          class PARAMS_T>
void ColoredMPPI::calculateSampledStateTrajectories()
{
  int num_sampled_trajectories = this->getTotalSampledTrajectories();
  // controls already copied in compute control

  mppi_common::launchStateAndCostTrajectoryKernel<DYN_T, COST_T, FEEDBACK_GPU, BDIM_X, BDIM_Y>(
      this->model_->model_d_, this->cost_->cost_d_, this->fb_controller_->getDevicePointer(), this->sampled_noise_d_,
      this->initial_state_d_, this->sampled_states_d_, this->sampled_costs_d_, this->sampled_crash_status_d_,
      num_sampled_trajectories, this->getNumTimesteps(), this->getDt(), this->vis_stream_);

  for (int i = 0; i < num_sampled_trajectories; i++)
  {
    // set initial state to the first location
    this->sampled_trajectories_[i].col(0) = this->state_.col(0);
    // shifted by one since we do not save the initial state
    HANDLE_ERROR(cudaMemcpyAsync(this->sampled_trajectories_[i].data() + (DYN_T::STATE_DIM),
                                 this->sampled_states_d_ + i * this->getNumTimesteps() * DYN_T::STATE_DIM,
                                 (this->getNumTimesteps() - 1) * DYN_T::STATE_DIM * sizeof(float),
                                 cudaMemcpyDeviceToHost, this->vis_stream_));
    HANDLE_ERROR(
        cudaMemcpyAsync(this->sampled_costs_[i].data(), this->sampled_costs_d_ + (i * (this->getNumTimesteps() + 1)),
                        (this->getNumTimesteps() + 1) * sizeof(float), cudaMemcpyDeviceToHost, this->vis_stream_));
    HANDLE_ERROR(cudaMemcpyAsync(this->sampled_crash_status_[i].data(),
                                 this->sampled_crash_status_d_ + (i * this->getNumTimesteps()),
                                 this->getNumTimesteps() * sizeof(float), cudaMemcpyDeviceToHost, this->vis_stream_));
  }
  HANDLE_ERROR(cudaStreamSynchronize(this->vis_stream_));
}

#undef ColoredMPPI
