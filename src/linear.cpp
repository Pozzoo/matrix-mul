#include "linear.h"
#include <algorithm>

#include "io_utils.h"

void matmul_linear(const DMatrix &A, const DMatrix &B, DMatrix &C, const int n) {
    std::ranges::fill(C, 0.0);
    for (int i = 0; i < n; ++i) {
        for (int k = 0; k < n; ++k) {
            const long double a = A[i*n + k];
            for (int j = 0; j < n; ++j) {
                C[i*n + j] += a * B[k*n + j];
            }
        }
    }
}
