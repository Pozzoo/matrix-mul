#include <mpi.h>
#include <vector>
#include <iostream>
#include "io_utils.h"
#include "linear.h"

using Matrix = std::vector<double>;

// Master-worker MPI: master (rank 0) reads matA and matB from /data and writes matC to /data

void matmul_mpi_distributed(const std::string& data_dir) {
    int rank, size;

    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (size < 2) {
        if (rank == 0) std::cerr << "[mpi] Need at least 2 processes (1 master + >=1 worker)\n";
        return;
    }

    if (rank == 0) {
        // master
        Matrix A, B, C;
        int nA=0, nB=0;

        const std::string pathA = data_dir + "/matA.txt";
        const std::string pathB = data_dir + "/matB.txt";

        if (!read_square_matrix(pathA, A, nA)) {
            std::cerr << "[mpi-master] failed to read " << pathA << "\n";
            return;
        }
        if (!read_square_matrix(pathB, B, nB)) {
            std::cerr << "[mpi-master] failed to read " << pathB << "\n";
            return;
        }
        if (nA != nB) {
            std::cerr << "[mpi-master] dimension mismatch\n";
            return;
        }

        int n = nA;
        C.assign(n*n, 0.0);

        // broadcast n
        MPI_Bcast(&n, 1, MPI_INT, 0, MPI_COMM_WORLD);
        // broadcast B
        MPI_Bcast(B.data(), n*n, MPI_DOUBLE, 0, MPI_COMM_WORLD);

        // divide rows among workers
        const int workers = size - 1;
        const int base = n / workers;
        const int rem = n % workers;
        int offset = 0;

        for (int w = 1; w <= workers; ++w) {
            int rows = base + (w <= rem ? 1 : 0);
            const int count = rows * n;

            // send the number of rows
            MPI_Send(&rows, 1, MPI_INT, w, 0, MPI_COMM_WORLD);

            // send A block
            if (count > 0)
                MPI_Send(A.data() + offset * n, count, MPI_DOUBLE, w, 0, MPI_COMM_WORLD);
            offset += rows;
        }

        // receive results
        offset = 0;
        for (int w = 1; w <= workers; ++w) {
            int rows;
            MPI_Recv(&rows, 1, MPI_INT, w, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);

            if (const int count = rows * n; count > 0)
                MPI_Recv(C.data() + offset * n, count, MPI_DOUBLE, w, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
            offset += rows;
        }

        // write matC
        if (const std::string out = data_dir + "/matC.txt"; !write_square_matrix(out, C, n)) {
            std::cerr << "[mpi-master] failed to write " << out << "\n";
        } else {
            std::cout << "[mpi-master] wrote " << out << "\n";
        }

    } else {
        // worker
        // receive n via bcast
        int n;
        MPI_Bcast(&n, 1, MPI_INT, 0, MPI_COMM_WORLD);
        Matrix B(n * n);
        MPI_Bcast(B.data(), n*n, MPI_DOUBLE, 0, MPI_COMM_WORLD);

        int rows;
        MPI_Recv(&rows, 1, MPI_INT, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);
        const int count = rows * n;

        Matrix Ablock(count);
        if (count > 0)
            MPI_Recv(Ablock.data(), count, MPI_DOUBLE, 0, 0, MPI_COMM_WORLD, MPI_STATUS_IGNORE);

        Matrix Cblock(count);
        if (count > 0)
            matmul_linear(Ablock, B, Cblock, n);

        // send back rows and result
        MPI_Send(&rows, 1, MPI_INT, 0, 0, MPI_COMM_WORLD);
        if (count > 0)
            MPI_Send(Cblock.data(), count, MPI_DOUBLE, 0, 0, MPI_COMM_WORLD);
    }
}
