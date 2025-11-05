#pragma once
#include <vector>

#include "io_utils.h"

using Matrix = std::vector<double>;

void matmul_linear(const DMatrix &A, const DMatrix &B, DMatrix &C, int n);
