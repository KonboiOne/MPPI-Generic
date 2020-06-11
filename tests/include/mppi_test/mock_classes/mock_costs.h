//
// Created by jason on 4/14/20.
//

#ifndef MPPIGENERIC_MOCK_COSTS_H
#define MPPIGENERIC_MOCK_COSTS_H

#include <gtest/gtest.h>
#include <gmock/gmock.h>
#include <mppi/cost_functions/cost.cuh>

// ===== mock cost ====
typedef struct {
  int test = 1;
} mockCostParams;

class MockCost : public Cost<MockCost, mockCostParams, 1, 1> {
public:
  MOCK_METHOD1(bindToStream, void(cudaStream_t stream));
  MOCK_METHOD0(getDebugDisplayEnabled, bool());
  MOCK_METHOD1(getDebugDisplay, cv::Mat(float* array));
  MOCK_METHOD1(setParams, void(mockCostParams params));
  MOCK_METHOD2(updateCostmap, void(std::vector<int> desc, std::vector<float> data));
  MOCK_METHOD0(GPUSetup, void());
};
#endif //MPPIGENERIC_MOCK_COSTS_H