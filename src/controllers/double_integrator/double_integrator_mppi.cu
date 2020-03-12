#include <mppi/instantiations/double_integrator_mppi/double_integrator_mppi.cuh>

/*
 * This file contains the instantiations of the controller for the cart pole.
 * Will have a dynamics model of cartpole, some cost function,
 * and a controller of just MPPI, (not tube or R)
 */
// Num_timesteps, num_rollouts, blockdim x, blockdim y
template class VanillaMPPIController<DoubleIntegratorDynamics, DoubleIntegratorCircleCost, 100, 512, 64, 8>;
template class TubeMPPIController<DoubleIntegratorDynamics, DoubleIntegratorCircleCost, 100, 512, 64, 8>;