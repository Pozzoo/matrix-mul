#pragma once
#include <vector>

using Matrix = std::vector<double>;

void matmul_linear(const Matrix &A, const Matrix &B, Matrix &C, int n);
