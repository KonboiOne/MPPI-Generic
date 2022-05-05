/**
 * Created by Manan Gandhi on 2/14/2020
 * API for interfacing with the TUBE MPPI controller.
 */

#ifndef MPPIGENERIC_TUBE_MPPI_CONTROLLER_CUH
#define MPPIGENERIC_TUBE_MPPI_CONTROLLER_CUH

#include <curand.h>
#include <mppi/controllers/controller.cuh>
#include <mppi/core/mppi_common.cuh>
#include <chrono>
#include <memory>
#include <iostream>

template <int C_DIM, int MAX_TIMESTEPS>
struct TubeMPPIParams : ControllerParams<C_DIM, MAX_TIMESTEPS>
{
  float nominal_threshold_ = 20;  // How much worse the actual system has to be compared to the nominal
};

template <class DYN_T, class COST_T, class FB_T, int MAX_TIMESTEPS, int NUM_ROLLOUTS, int BDIM_X, int BDIM_Y,
          class PARAMS_T = TubeMPPIParams<COST_T::CONTROL_DIM, MAX_TIMESTEPS>>
class TubeMPPIController : public Controller<DYN_T, COST_T, FB_T, MAX_TIMESTEPS, NUM_ROLLOUTS, BDIM_X, BDIM_Y, PARAMS_T>
{
public:
  //    EIGEN_MAKE_ALIGNED_OPERATOR_NEW unnecessary due to EIGEN_MAX_ALIGN_BYTES=0
  /**
   * Set up useful types
   */
  typedef Controller<DYN_T, COST_T, FB_T, MAX_TIMESTEPS, NUM_ROLLOUTS, BDIM_X, BDIM_Y, PARAMS_T> PARENT_CLASS;
  using control_array = typename PARENT_CLASS::control_array;
  using control_trajectory = typename PARENT_CLASS::control_trajectory;
  using state_trajectory = typename PARENT_CLASS::state_trajectory;
  using state_array = typename PARENT_CLASS::state_array;
  using sampled_cost_traj = typename PARENT_CLASS::sampled_cost_traj;
  using FEEDBACK_PARAMS = typename PARENT_CLASS::TEMPLATED_FEEDBACK_PARAMS;
  using FEEDBACK_GPU = typename PARENT_CLASS::TEMPLATED_FEEDBACK_GPU;

  TubeMPPIController(DYN_T* model, COST_T* cost, FB_T* fb_controller, float dt, int max_iter, float lambda, float alpha,
                     const Eigen::Ref<const control_array>& control_std_dev, int num_timesteps = MAX_TIMESTEPS,
                     const Eigen::Ref<const control_trajectory>& init_control_traj = control_trajectory::Zero(),
                     cudaStream_t stream = nullptr);

  TubeMPPIController(DYN_T* model, COST_T* cost, FB_T* fb_controller, PARAMS_T& params, cudaStream_t stream = nullptr);

  void computeControl(const Eigen::Ref<const state_array>& state, int optimization_stride = 1) override;

  std::string getControllerName()
  {
    return "Tube MPPI";
  };

  /**
   * returns the current nominal control sequence
   */
  control_trajectory getControlSeq() const override
  {
    return nominal_control_trajectory_;
  };

  /**
   * returns the current nominal state sequence
   */
  state_trajectory getTargetStateSeq() const override
  {
    return nominal_state_trajectory_;
  };

  /**
   * returns the current control sequence
   */
  control_trajectory getActualControlSeq()
  {
    return this->control_;
  };

  /**
   * Slide the control sequence back n steps
   */
  void slideControlSequence(int steps) override;

  void smoothControlTrajectory();

  void updateNominalState(const Eigen::Ref<const control_array>& u);

  float getNominalThreshold() const
  {
    return this->params_.nominal_threshold_;
  }
  void setNominalThreshold(float threshold)
  {
    this->params_.nominal_threshold_ = threshold;
  }

  void setPercentageSampledControlTrajectories(float new_perc)
  {
    this->setPercentageSampledControlTrajectoriesHelper(new_perc, 2);
  }

  void calculateSampledStateTrajectories() override;

private:
  float normalizer_nominal_;      // Variable for the normalizing term from sampling.
  float baseline_nominal_;        // Baseline cost of the system.
  float nominal_threshold_ = 20;  // How much worse the actual system has to be compared to the nominal

  // Free energy variables
  float nominal_free_energy_mean_ = 0;
  float nominal_free_energy_variance_ = 0;
  float nominal_free_energy_modified_variance_ = 0;

  // nominal state CPU side copies
  control_trajectory nominal_control_trajectory_ = control_trajectory::Zero();
  state_trajectory nominal_state_trajectory_ = state_trajectory::Zero();
  sampled_cost_traj trajectory_costs_nominal_ = sampled_cost_traj::Zero();

  // Check to see if nominal state has been initialized
  bool nominalStateInit_ = false;

  void computeStateTrajectory(const Eigen::Ref<const state_array>& x0_actual);

protected:
  // TODO move up and generalize, pass in what to copy and initial location
  void copyControlToDevice();

private:
  // ======== PURE VIRTUAL =========
  void allocateCUDAMemory();
  // ======== PURE VIRTUAL END =====
};

#if __CUDACC__
#include "tube_mppi_controller.cu"
#endif

#endif
