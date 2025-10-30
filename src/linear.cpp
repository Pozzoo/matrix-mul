#include "linear.h"
#include <algorithm>

void matmul_linear(const Matrix &A, const Matrix &B, Matrix &C, const int n) {
    std::ranges::fill(C, 0.0);
    for (int i = 0; i < n; ++i) {
        for (int k = 0; k < n; ++k) {
            const double a = A[i*n + k];
            for (int j = 0; j < n; ++j) {
                C[i*n + j] += a * B[k*n + j];
            }
        }
    }
}
