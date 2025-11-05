#include <iostream>
#include <string>
#include <chrono>
#include <mpi.h>
#include <thread>

#include "io_utils.h"
#include "linear.h"
#include "multithreaded.h"

// declare MPI wrapper
void matmul_mpi_distributed(const std::string& data_dir, int num_threads);

int main(int argc, char** argv) {
    std::string mode = "linear";
    std::string data_dir = "/data";

    // parse args like: --mode linear --data /data
    for (int i = 1; i < argc; ++i) {
        if (std::string s = argv[i]; s == "--mode" && i+1 < argc) mode = argv[++i];
        else if (s == "--data" && i+1 < argc) data_dir = argv[++i];
    }

    if (mode == "linear") {
        int na = 0, nb = 0;
        std::string pathA = data_dir + "/matA.txt";
        std::string pathB = data_dir + "/matB.txt";
        if (DMatrix A, B; read_square_matrix(pathA,A,na) && read_square_matrix(pathB,B,nb) && na==nb) {
            DMatrix C;
            int nread = na;

            C.assign(nread*nread,0.0);

            auto t0 = std::chrono::high_resolution_clock::now();

            matmul_linear(A,B,C,nread);

            auto t1 = std::chrono::high_resolution_clock::now();
            std::chrono::duration<double> dt = t1 - t0;

            std::cout << "[linear] n=" << nread <<" time=" << dt.count() << "s\n";

            write_square_matrix(data_dir + "/matC.txt", C, nread);
        } else {
            std::cout << "[linear] No matrix found!";
        }

        return 0;
    }

    const auto processor_count = std::thread::hardware_concurrency();
    std::cout << "[entry] Detected CPU count: " << processor_count << std::endl;

    if (mode == "mpi") {
        MPI_Init(&argc, &argv);
        matmul_mpi_distributed(data_dir, static_cast<int>(processor_count));
        MPI_Finalize();
        return 0;
    }

    if (mode == "mt") {
        int na=0, nb=0;
        std::string pathA = data_dir + "/matA.txt";
        std::string pathB = data_dir + "/matB.txt";

        if (DMatrix A, B; read_square_matrix(pathA,A,na) && read_square_matrix(pathB,B,nb) && na==nb) {
            DMatrix C;
            int nread = na;

            C.assign(nread*nread,0.0);

            auto t0 = std::chrono::high_resolution_clock::now();

            matmul_mt(A,B,C,nread, static_cast<int>(processor_count));

            auto t1 = std::chrono::high_resolution_clock::now();
            std::chrono::duration<double> dt = t1 - t0;

            std::cout << "[mt] n=" << nread << " threads=" << processor_count << " time=" << dt.count() << "s\n";

            write_square_matrix(data_dir + "/matC.txt", C, nread);
        } else {
            std::cout << "[mt] No matrix found!";
        }
        return 0;
    }

    std::cerr << "Unknown mode: " << mode << " (use linear | mt | mpi)\n";
    return 1;
}
