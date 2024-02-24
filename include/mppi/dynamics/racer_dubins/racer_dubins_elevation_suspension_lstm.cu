//
// Created by Bogdan on 02/21/2024
//

#include <eigen3/Eigen/src/Geometry/Quaternion.h>
#include "racer_dubins_elevation_suspension_lstm.cuh"

#define TEMPLATE_TYPE template <class CLASS_T, class PARAMS_T>
#define TEMPLATE_NAME RacerDubinsElevationSuspensionImpl<CLASS_T, PARAMS_T>

TEMPLATE_TYPE
TEMPLATE_NAME::RacerDubinsElevationSuspensionImpl(cudaStream_t stream)
  : RacerDubinsElevationLSTMSteeringImpl<CLASS_T, PARAMS_T>(stream)
{
  this->requires_buffer_ = true;
  this->lstm_lstm_helper_ = std::make_shared<NN>(stream);
  normals_tex_helper_ = new TwoDTextureHelper<float4>(1, stream);
}

TEMPLATE_TYPE
TEMPLATE_NAME::RacerDubinsElevationSuspensionImpl(PARAMS_T& params, cudaStream_t stream)
  : RacerDubinsElevationLSTMSteeringImpl<CLASS_T, PARAMS_T>(params, stream)
{
  this->requires_buffer_ = true;
  this->lstm_lstm_helper_ = std::make_shared<NN>(stream);
  normals_tex_helper_ = new TwoDTextureHelper<float4>(1, stream);
}

TEMPLATE_TYPE
TEMPLATE_NAME::RacerDubinsElevationSuspensionImpl(std::string path, cudaStream_t stream)
  : RacerDubinsElevationLSTMSteeringImpl<CLASS_T, PARAMS_T>(stream)
{
  if (!fileExists(path))
  {
    std::cerr << "Could not load neural net model at path: " << path.c_str();
    exit(-1);
  }
  cnpy::npz_t param_dict = cnpy::npz_load(path);
  this->params_.max_steer_rate = param_dict.at("parameters/max_rate_pos").data<float>()[0];
  this->params_.steering_constant = param_dict.at("parameters/constant").data<float>()[0];
  this->params_.steer_accel_constant = param_dict.at("parameters/accel_constant").data<float>()[0];
  this->params_.steer_accel_drag_constant = param_dict.at("parameters/accel_drag_constant").data<float>()[0];
  this->lstm_lstm_helper_ = std::make_shared<NN>(path, stream);
  this->requires_buffer_ = true;
  normals_tex_helper_ = new TwoDTextureHelper<float4>(1, stream);
}

TEMPLATE_TYPE
void TEMPLATE_NAME::paramsToDevice()
{
  normals_tex_helper_->copyToDevice();
  PARENT_CLASS::paramsToDevice();
}

TEMPLATE_TYPE
void TEMPLATE_NAME::GPUSetup()
{
  PARENT_CLASS::GPUSetup();

  normals_tex_helper_->GPUSetup();
  // makes sure that the device ptr sees the correct texture object
  HANDLE_ERROR(cudaMemcpyAsync(&(this->model_d_->normals_tex_helper_), &(normals_tex_helper_->ptr_d_),
                               sizeof(TwoDTextureHelper<float4>*), cudaMemcpyHostToDevice, this->stream_));
}

TEMPLATE_TYPE
void TEMPLATE_NAME::freeCudaMem()
{
  normals_tex_helper_->freeCudaMem();
  PARENT_CLASS::freeCudaMem();
}

TEMPLATE_TYPE
void TEMPLATE_NAME::step(Eigen::Ref<state_array> state, Eigen::Ref<state_array> next_state,
                         Eigen::Ref<state_array> state_der, const Eigen::Ref<const control_array>& control,
                         Eigen::Ref<output_array> output, const float t, const float dt)
{
  this->computeParametricDelayDeriv(state, control, state_der);
  this->computeParametricAccelDeriv(state, control, state_der, dt);

  DYN_PARAMS_T* params_p = &(this->params_);

  const float parametric_accel =
      fmaxf(fminf((control(C_INDEX(STEER_CMD)) * params_p->steer_command_angle_scale - state(S_INDEX(STEER_ANGLE))) *
                      params_p->steering_constant,
                  params_p->max_steer_rate),
            -params_p->max_steer_rate);
  state_der(S_INDEX(STEER_ANGLE_RATE)) =
      (parametric_accel - state(S_INDEX(STEER_ANGLE_RATE))) * params_p->steer_accel_constant -
      state(S_INDEX(STEER_ANGLE_RATE)) * params_p->steer_accel_drag_constant;

  typename LSTM::input_array input;
  input(0) = state(S_INDEX(STEER_ANGLE)) * 0.2f;
  input(1) = state(S_INDEX(STEER_ANGLE_RATE)) * 0.2f;
  input(2) = control(C_INDEX(STEER_CMD));
  input(3) = state_der(S_INDEX(STEER_ANGLE_RATE)) * 0.2f;  // this is the parametric part as input
  typename LSTM::output_array nn_output = LSTM::output_array::Zero();
  this->lstm_lstm_helper_->forward(input, nn_output);
  state_der(S_INDEX(STEER_ANGLE_RATE)) += nn_output(0) * 5.0f;
  state_der(S_INDEX(STEER_ANGLE)) = state(S_INDEX(STEER_ANGLE_RATE));

  // Calculate suspension-based state derivatives
  const float& x = state(S_INDEX(POS_X));
  const float& y = state(S_INDEX(POS_Y));
  const float& roll = state(S_INDEX(ROLL));
  const float& pitch = state(S_INDEX(PITCH));
  const float& yaw = state(S_INDEX(YAW));
  float3 wheel_positions_body[W_INDEX(NUM_WHEELS)];
  float3 wheel_positions_world[W_INDEX(NUM_WHEELS)];
  float3 wheel_positions_cg[W_INDEX(NUM_WHEELS)];
  wheel_positions_body[W_INDEX(FR)] = make_float3(2.981f, -0.737f, 0.f);
  wheel_positions_body[W_INDEX(FL)] = make_float3(2.981f, 0.737f, 0.0f);
  wheel_positions_body[W_INDEX(BR)] = make_float3(0.0f, 0.737f, 0.0f);
  wheel_positions_body[W_INDEX(BL)] = make_float3(0.0f, -0.737f, 0.f);

  float3 body_pose = make_float3(x, y, 0.0f);
  // rotation matrix representation
  // float3 rotation = make_float3(roll, pitch, yaw);
  Eigen::Matrix3f M;
  mppi::math::Euler2DCM_NWU(roll, pitch, yaw, M);
  float wheel_pos_z, wheel_vel_z;
  float wheel_height = 0.0f;
  float4 wheel_normal_world = make_float4(0.0f, 0.0f, 1.0f, 0.0f);
  float3 wheel_normal_body;
  int pi, step;

  state_der(S_INDEX(ROLL)) = state(S_INDEX(ROLL_RATE));
  state_der(S_INDEX(PITCH)) = state(S_INDEX(PITCH_RATE));
  state_der(S_INDEX(POS_Z)) = state(S_INDEX(VEL_Z));
  state_der(S_INDEX(VEL_Z)) = 0.0f;
  state_der(S_INDEX(ROLL_RATE)) = 0.0f;
  state_der(S_INDEX(PITCH_RATE)) = 0.0f;
  mppi::p1::getParallel1DIndex<mppi::p1::Parallel1Dir::THREAD_Y>(pi, step);
  for (int i = pi; i < W_INDEX(NUM_WHEELS); i += step)
  {
    // Calculate wheel position in different frames
    wheel_positions_cg[i] = wheel_positions_body[i] - params_p->c_g;
    mppi::math::bodyOffsetToWorldPoseDCM(wheel_positions_body[i], body_pose, M, wheel_positions_world[i]);
    if (this->tex_helper_->checkTextureUse(0))
    {
      wheel_height = this->tex_helper_->queryTextureAtWorldPose(0, wheel_positions_world[i]);
    }
    if (normals_tex_helper_->checkTextureUse(0))
    {
      wheel_normal_world = normals_tex_helper_->queryTextureAtWorldPose(0, wheel_positions_world[i]);
    }

    // get normals in body position
    mppi::math::RotatePointByDCM(M, *(float3*)(&wheel_normal_world), wheel_normal_body);

    // Calculate wheel heights, velocities, and forces
    wheel_pos_z = state(S_INDEX(POS_Z)) + roll * wheel_positions_cg[i].y - pitch * wheel_positions_cg[i].x;
    wheel_vel_z = state(S_INDEX(VEL_Z)) + state(S_INDEX(ROLL_RATE)) * wheel_positions_cg[i].y -
                  state(S_INDEX(PITCH_RATE)) * wheel_positions_cg[i].x;
    // V_x * N_x + V_y * N_y
    float h_dot = -state(S_INDEX(VEL_X)) * wheel_normal_body.x;
    output(O_INDEX(WHEEL_FORCE_B_FL) + i) =
        -params_p->spring_k * (wheel_pos_z - wheel_height) - params_p->drag_c * (wheel_vel_z - h_dot);
    state_der(S_INDEX(VEL_Z)) += output(O_INDEX(WHEEL_FORCE_B_FL) + i) / params_p->mass;
    state_der(S_INDEX(ROLL_RATE)) += output(O_INDEX(WHEEL_FORCE_B_FL) + i) * wheel_positions_cg[i].y / params_p->I_xx;
    state_der(S_INDEX(PITCH_RATE)) += -output(O_INDEX(WHEEL_FORCE_B_FL) + i) * wheel_positions_cg[i].x / params_p->I_yy;
  }

  // Integrate using Euler Integration
  updateState(state, next_state, state_der, dt);
  SharedBlock sb;
  computeUncertaintyPropagation(state.data(), control.data(), state_der.data(), next_state.data(), dt, &this->params_,
                                &sb);

  // float roll = state(S_INDEX(ROLL));
  // float pitch = state(S_INDEX(PITCH));
  // RACER::computeStaticSettling<typename DYN_PARAMS_T::OutputIndex, TwoDTextureHelper<float>>(
  //     this->tex_helper_, next_state(S_INDEX(YAW)), next_state(S_INDEX(POS_X)), next_state(S_INDEX(POS_Y)), roll,
  //     pitch, output.data());
  // next_state[S_INDEX(PITCH)] = pitch;
  // next_state[S_INDEX(ROLL)] = roll;

  this->setOutputs(state_der.data(), next_state.data(), output.data());
  // printf("CPU t: %3.0f, VEL_Z(t + 1): %f, VEL_Z(t): %f, VEl_Z'(t): %f\n", t, next_state(S_INDEX(VEL_Z)),
  // state(S_INDEX(VEL_Z)),
  //     state_der(S_INDEX(VEL_Z)));
}

TEMPLATE_TYPE
__device__ void TEMPLATE_NAME::step(float* state, float* next_state, float* state_der, float* control, float* output,
                                    float* theta_s, const float t, const float dt)
{
  DYN_PARAMS_T* params_p;
  SharedBlock *sb_mem, *sb;
  if (GRANDPARENT_CLASS::SHARED_MEM_REQUEST_GRD_BYTES != 0)
  {  // Allows us to turn on or off global or shared memory version of params
    params_p = (DYN_PARAMS_T*)theta_s;
  }
  else
  {
    params_p = &(this->params_);
  }
  if (GRANDPARENT_CLASS::SHARED_MEM_REQUEST_BLK_BYTES != 0)
  {
    sb_mem = (SharedBlock*)&theta_s[mppi::math::int_multiple_const(GRANDPARENT_CLASS::SHARED_MEM_REQUEST_GRD_BYTES,
                                                                   sizeof(float4)) /
                                    sizeof(float)];
    sb = &sb_mem[threadIdx.x + blockDim.x * threadIdx.z];
  }
  computeParametricDelayDeriv(state, control, state_der, params_p);
  computeParametricAccelDeriv(state, control, state_der, dt, params_p);

  // computes the velocity dot
  int pi, step;
  mppi::p1::getParallel1DIndex<mppi::p1::Parallel1Dir::THREAD_Y>(pi, step);

  const int shift =
      (mppi::math::int_multiple_const(GRANDPARENT_CLASS::SHARED_MEM_REQUEST_GRD_BYTES, sizeof(float4)) +
       blockDim.x * blockDim.z *
           mppi::math::int_multiple_const(GRANDPARENT_CLASS::SHARED_MEM_REQUEST_BLK_BYTES, sizeof(float4))) /
      sizeof(float);
  // loads in the input to the network
  float* input_loc = this->network_d_->getInputLocation(theta_s + shift);
  if (pi == 0)
  {
    const float parametric_accel =
        fmaxf(fminf((control[C_INDEX(STEER_CMD)] * params_p->steer_command_angle_scale - state[S_INDEX(STEER_ANGLE)]) *
                        params_p->steering_constant,
                    params_p->max_steer_rate),
              -params_p->max_steer_rate);
    state_der[S_INDEX(STEER_ANGLE_RATE)] =
        (parametric_accel - state[S_INDEX(STEER_ANGLE_RATE)]) * params_p->steer_accel_constant -
        state[S_INDEX(STEER_ANGLE_RATE)] * params_p->steer_accel_drag_constant;

    input_loc[0] = state[S_INDEX(STEER_ANGLE)] * 0.2f;
    input_loc[1] = state[S_INDEX(STEER_ANGLE_RATE)] * 0.2f;
    input_loc[2] = control[C_INDEX(STEER_CMD)];
    input_loc[3] = state_der[S_INDEX(STEER_ANGLE_RATE)] * 0.2f;  // this is the parametric part as input
  }
  __syncthreads();
  // runs the network
  float* nn_output = this->network_d_->forward(nullptr, theta_s + shift);
  // copies the results of the network to state derivative
  if (pi == 0)
  {
    state_der[S_INDEX(STEER_ANGLE_RATE)] += nn_output[0] * 5.0f;
    state_der[S_INDEX(STEER_ANGLE)] = state[S_INDEX(STEER_ANGLE_RATE)];
    state_der[S_INDEX(VEL_Z)] = 0.0f;
    state_der[S_INDEX(ROLL_RATE)] = 0.0f;
    state_der[S_INDEX(PITCH_RATE)] = 0.0f;
    state_der[S_INDEX(ROLL)] = state[S_INDEX(ROLL_RATE)];
    state_der[S_INDEX(PITCH)] = state[S_INDEX(PITCH_RATE)];
    state_der[S_INDEX(POS_Z)] = state[S_INDEX(VEL_Z)];
  }
  __syncthreads();
  // Calculate suspension-based state derivatives
  const float& x = state[S_INDEX(POS_X)];
  const float& y = state[S_INDEX(POS_Y)];
  const float& roll = state[S_INDEX(ROLL)];
  const float& pitch = state[S_INDEX(PITCH)];
  const float& yaw = state[S_INDEX(YAW)];
  float3 wheel_positions_body;
  float3 wheel_positions_world;

  float3 body_pose = make_float3(x, y, 0.0f);
  float3 rotation = make_float3(roll, pitch, yaw);
  // rotation matrix representation
  // TODO Check if M needs to be in shared memory
  float M[3][3];
  mppi::math::Euler2DCM_NWU(roll, pitch, yaw, M);
  // mppi::math::Euler2DCM_NWU(rotation.x, rotation.y, rotation.z, M);
  float wheel_pos_z, wheel_vel_z;
  float wheel_height = 0.0f;
  float h_dot = 0.0f;
  float4 wheel_normal_world = make_float4(0.0f, 0.0f, 1.0f, 0.0f);
  float3 wheel_normal_body;
  float3 wheel_positions_cg;

  for (int i = pi; i < W_INDEX(NUM_WHEELS); i += step)
  {
    // get body frame wheel positions
    switch (i)
    {
      case W_INDEX(FR):
        wheel_positions_body = make_float3(2.981f, -0.737f, 0.f);
        break;
      case W_INDEX(FL):
        wheel_positions_body = make_float3(2.981f, 0.737f, 0.0f);
        break;
      case W_INDEX(BR):
        wheel_positions_body = make_float3(0.0f, 0.737f, 0.0f);
        break;
      case W_INDEX(BL):
        wheel_positions_body = make_float3(0.0f, -0.737f, 0.f);
        break;
      default:
        break;
    }

    // Calculate wheel position in different frames
    wheel_positions_cg = wheel_positions_body - params_p->c_g;
    mppi::math::bodyOffsetToWorldPoseDCM(wheel_positions_body, body_pose, M, wheel_positions_world);
    if (this->tex_helper_->checkTextureUse(0))
    {
      wheel_height = this->tex_helper_->queryTextureAtWorldPose(0, wheel_positions_world);
    }
    if (normals_tex_helper_->checkTextureUse(0))
    {
      wheel_normal_world = normals_tex_helper_->queryTextureAtWorldPose(0, wheel_positions_world);
    }

    // get normals in body position
    mppi::math::RotatePointByDCM(M, *(float3*)(&wheel_normal_world), wheel_normal_body);

    // Calculate wheel heights, velocities, and forces
    wheel_pos_z = state[S_INDEX(POS_Z)] + roll * wheel_positions_cg.y - pitch * wheel_positions_cg.x;
    wheel_vel_z = state[S_INDEX(VEL_Z)] + state[S_INDEX(ROLL_RATE)] * wheel_positions_cg.y -
                  state[S_INDEX(PITCH_RATE)] * wheel_positions_cg.x;
    // V_x * N_x + V_y * N_y
    h_dot = -state[S_INDEX(VEL_X)] * wheel_normal_body.x;

    output[O_INDEX(WHEEL_FORCE_B_FL) + i] =
        -params_p->spring_k * (wheel_pos_z - wheel_height) - params_p->drag_c * (wheel_vel_z - h_dot);
    atomicAdd_block(&state_der[S_INDEX(VEL_Z)], output[O_INDEX(WHEEL_FORCE_B_FL) + i] / params_p->mass);
    atomicAdd_block(&state_der[S_INDEX(ROLL_RATE)],
                    output[O_INDEX(WHEEL_FORCE_B_FL) + i] * wheel_positions_cg.y / params_p->I_xx);
    atomicAdd_block(&state_der[S_INDEX(PITCH_RATE)],
                    -output[O_INDEX(WHEEL_FORCE_B_FL) + i] * wheel_positions_cg.x / params_p->I_yy);
  }

  __syncthreads();

  updateState(state, next_state, state_der, dt);
  computeUncertaintyPropagation(state, control, state_der, next_state, dt, params_p, sb);
  // if (pi == 0)
  // {
  //   float roll = state[S_INDEX(ROLL)];
  //   float pitch = state[S_INDEX(PITCH)];
  //   RACER::computeStaticSettling<DYN_PARAMS_T::OutputIndex, TwoDTextureHelper<float>>(
  //       this->tex_helper_, next_state[S_INDEX(YAW)], next_state[S_INDEX(POS_X)], next_state[S_INDEX(POS_Y)], roll,
  //       pitch, output);
  //   next_state[S_INDEX(PITCH)] = pitch;
  //   next_state[S_INDEX(ROLL)] = roll;
  // }
  __syncthreads();
  // if (threadIdx.x == 0 && blockIdx.x == 0 && threadIdx.y == 0)
  // {
  //   printf("GPU t: %3d, VEL_Z(t + 1): %f, VEL_Z(t): %f, VEl_Z'(t): %f\n", t, next_state[S_INDEX(VEL_Z)],
  //   state[S_INDEX(VEL_Z)],
  //       state_der[S_INDEX(VEL_Z)]);
  // }
  this->setOutputs(state_der, next_state, output);
}

TEMPLATE_TYPE
__device__ void TEMPLATE_NAME::updateState(float* state, float* next_state, float* state_der, const float dt)
{
  int i;
  int tdy, step;
  mppi::p1::getParallel1DIndex<mppi::p1::Parallel1Dir::THREAD_Y>(tdy, step);
  // Add the state derivative time dt to the current state.
  for (i = tdy; i < S_INDEX(STEER_ANGLE_RATE); i += step)
  {
    next_state[i] = state[i] + state_der[i] * dt;
    if (i == S_INDEX(YAW))
    {
      next_state[i] = angle_utils::normalizeAngle(next_state[i]);
    }
    if (i == S_INDEX(STEER_ANGLE))
    {
      next_state[i] = fmaxf(fminf(next_state[i], this->params_.max_steer_angle), -this->params_.max_steer_angle);
      next_state[S_INDEX(STEER_ANGLE_RATE)] =
          state[S_INDEX(STEER_ANGLE_RATE)] + state_der[S_INDEX(STEER_ANGLE_RATE)] * dt;
    }
    if (i == S_INDEX(BRAKE_STATE))
    {
      next_state[i] = fminf(fmaxf(next_state[i], 0.0f), 1.0f);
    }
  }
}

TEMPLATE_TYPE
void TEMPLATE_NAME::updateState(const Eigen::Ref<const state_array> state, Eigen::Ref<state_array> next_state,
                                Eigen::Ref<state_array> state_der, const float dt)
{
  // Segmented it to ensure that roll and pitch don't get overwritten
  for (int i = 0; i < S_INDEX(STEER_ANGLE_RATE); i++)
  {
    next_state[i] = state[i] + state_der[i] * dt;
  }
  next_state(S_INDEX(YAW)) = angle_utils::normalizeAngle(next_state(S_INDEX(YAW)));
  next_state(S_INDEX(STEER_ANGLE)) =
      fmaxf(fminf(next_state(S_INDEX(STEER_ANGLE)), this->params_.max_steer_angle), -this->params_.max_steer_angle);
  next_state(S_INDEX(STEER_ANGLE_RATE)) = state(S_INDEX(STEER_ANGLE_RATE)) + state_der(S_INDEX(STEER_ANGLE_RATE)) * dt;
  next_state(S_INDEX(BRAKE_STATE)) =
      fminf(fmaxf(next_state(S_INDEX(BRAKE_STATE)), 0.0f), -this->control_rngs_[C_INDEX(THROTTLE_BRAKE)].x);
}

TEMPLATE_TYPE
__host__ __device__ void TEMPLATE_NAME::setOutputs(const float* state_der, const float* next_state, float* output)
{
  // Setup output

  int step, pi;
  mp1::getParallel1DIndex<mp1::Parallel1Dir::THREAD_Y>(pi, step);
  for (int i = pi; i < this->OUTPUT_DIM; i += step)
  {
    switch (i)
    {
      case O_INDEX(BASELINK_VEL_B_X):
        output[i] = next_state[S_INDEX(VEL_X)];
        break;
      case O_INDEX(BASELINK_VEL_B_Y):
        output[i] = 0.0f;
        break;
      // case O_INDEX(BASELINK_VEL_B_Z):
      //   output[i] = 0.0f;
      //   break;
      case O_INDEX(BASELINK_POS_I_X):
        output[i] = next_state[S_INDEX(POS_X)];
        break;
      case O_INDEX(BASELINK_POS_I_Y):
        output[i] = next_state[S_INDEX(POS_Y)];
        break;
      case O_INDEX(PITCH):
        output[i] = next_state[S_INDEX(PITCH)];
        break;
      case O_INDEX(ROLL):
        output[i] = next_state[S_INDEX(ROLL)];
        break;
      case O_INDEX(YAW):
        output[i] = next_state[S_INDEX(YAW)];
        break;
      case O_INDEX(STEER_ANGLE):
        output[i] = next_state[S_INDEX(STEER_ANGLE)];
        break;
      case O_INDEX(STEER_ANGLE_RATE):
        output[i] = next_state[S_INDEX(STEER_ANGLE_RATE)];
        break;
      case O_INDEX(ACCEL_X):
        output[i] = state_der[S_INDEX(VEL_X)];
        break;
      case O_INDEX(ACCEL_Y):
        output[i] = 0.0f;
        break;
      case O_INDEX(OMEGA_Z):
        output[i] = state_der[S_INDEX(YAW)];
        break;
      case O_INDEX(UNCERTAINTY_VEL_X):
        output[i] = next_state[S_INDEX(UNCERTAINTY_VEL_X)];
        break;
      case O_INDEX(UNCERTAINTY_YAW_VEL_X):
        output[i] = next_state[S_INDEX(UNCERTAINTY_YAW_VEL_X)];
        break;
      case O_INDEX(UNCERTAINTY_POS_X_VEL_X):
        output[i] = next_state[S_INDEX(UNCERTAINTY_POS_X_VEL_X)];
        break;
      case O_INDEX(UNCERTAINTY_POS_Y_VEL_X):
        output[i] = next_state[S_INDEX(UNCERTAINTY_POS_Y_VEL_X)];
        break;
      case O_INDEX(UNCERTAINTY_YAW):
        output[i] = next_state[S_INDEX(UNCERTAINTY_YAW)];
        break;
      case O_INDEX(UNCERTAINTY_POS_X_YAW):
        output[i] = next_state[S_INDEX(UNCERTAINTY_POS_X_YAW)];
        break;
      case O_INDEX(UNCERTAINTY_POS_Y_YAW):
        output[i] = next_state[S_INDEX(UNCERTAINTY_POS_Y_YAW)];
        break;
      case O_INDEX(UNCERTAINTY_POS_X):
        output[i] = next_state[S_INDEX(UNCERTAINTY_POS_X)];
        break;
      case O_INDEX(UNCERTAINTY_POS_X_Y):
        output[i] = next_state[S_INDEX(UNCERTAINTY_POS_X_Y)];
        break;
      case O_INDEX(UNCERTAINTY_POS_Y):
        output[i] = next_state[S_INDEX(UNCERTAINTY_POS_Y)];
        break;
      case O_INDEX(TOTAL_VELOCITY):
        output[i] = fabsf(next_state[S_INDEX(VEL_X)]);
        break;
    }
  }
}
#undef TEMPLATE_NAME
#undef TEMPLATE_TYPE