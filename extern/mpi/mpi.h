// Minimal dummy header so IDE stops complaining.
// This is NOT used during compilation inside Docker.

#pragma once
int MPI_Init(int*, char***);
int MPI_Finalize();
int MPI_Comm_rank(int, int*);
int MPI_Comm_size(int, int*);
int MPI_Send(const void*, int, int, int, int, int);
int MPI_Recv(void*, int, int, int, int, int, void*);
int MPI_Bcast(void*, int, int, int, int);
int MPI_Barrier(int);
#define MPI_COMM_WORLD 0
#define MPI_DOUBLE 0
#define MPI_INT 0
