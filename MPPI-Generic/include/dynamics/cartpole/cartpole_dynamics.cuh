#pragma once

#ifndef CARTPOLE_CUH_
#define CARTPOLE_CUH_

#include <dynamics/dynamics.cuh>

struct CartpoleDynamicsParams {
    float cart_mass = 1.0f;
    float pole_mass = 1.0f;
    float pole_length = 1.0f;

    CartpoleDynamicsParams() = default;
    CartpoleDynamicsParams(float cart_mass, float pole_mass, float pole_length):
    cart_mass(cart_mass), pole_mass(pole_mass), pole_length(pole_length) {};
};

class CartpoleDynamics : public Dynamics<CartpoleDynamics, CartpoleDynamicsParams, 4, 1>
{
public:
    CartpoleDynamics(float delta_t, float cart_mass, float pole_mass,
                     float pole_length, cudaStream_t stream=0);
    ~CartpoleDynamics();

    /**
     * runs dynamics using state and control and sets it to state
     * derivative. Everything is Eigen Matrices, not Eigen Vectors!
     *
     * @param state     input of current state, passed by reference
     * @param control   input of currrent control, passed by reference
     * @param state_der output of new state derivative, passed by reference
     */
    void computeDynamics(Eigen::MatrixXf &state,
              Eigen::MatrixXf &control,
              Eigen::MatrixXf &state_der);

    /**
     * compute the Jacobians with respect to state and control
     *
     * @param state   input of current state, passed by reference
     * @param control input of currrent control, passed by reference
     * @param A       output Jacobian wrt state, passed by reference
     * @param B       output Jacobian wrt control, passed by reference
     */
    void computeGrad(Eigen::MatrixXf &state,
                     Eigen::MatrixXf &control,
                     Eigen::MatrixXf &A,
                     Eigen::MatrixXf &B);

    __host__ __device__ float getCartMass() {return this->params_.cart_mass;};
    __host__ __device__ float getPoleMass() {return this->params_.pole_mass;};
    __host__ __device__ float getPoleLength() {return this->params_.pole_length;};
    __host__ __device__ float getGravity() {return gravity_;}

    void printState(Eigen::MatrixXf state);
    void printState(float* state);
    void printParams();

    __device__ void computeDynamics(float* state,
                                  float* control,
                                  float* state_der, float* theta = nullptr);

    void freeCudaMem();

    void paramsToDevice();



protected:
    const float gravity_ = 9.81;

};

#if __CUDACC__
#include "cartpole_dynamics.cu"
#endif

#endif // CARTPOLE_CUH_