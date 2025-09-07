#define GLM_FORCE_CUDA

#include <cuda.h>
#include "kernel.h"
#include "utilityCore.hpp"

#include <cmath>
#include <cstdio>
#include <iostream>
#include <vector>

#include <thrust/sort.h>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/device_vector.h>

#include <glm/glm.hpp>

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char *msg, int line = -1) {
  cudaError_t err = cudaGetLastError();
  if (cudaSuccess != err) {
    if (line >= 0) {
      fprintf(stderr, "Line %d: ", line);
    }
    fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
    exit(EXIT_FAILURE);
  }
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// Based on 27 cells * 2 for start/end, + padding so it's a multiple of 32
#define sharedGridIndicesSize 64

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3 *dev_pos;
glm::vec3 *dev_vel1;
glm::vec3 *dev_vel2;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int *dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int *dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int *dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int *dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.
glm::vec3 *dev_pos_sorted;
glm::vec3 *dev_vel_sorted;
glm::vec3 *dev_vel_out;

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
  a = (a + 0x7ed55d16) + (a << 12);
  a = (a ^ 0xc761c23c) ^ (a >> 19);
  a = (a + 0x165667b1) + (a << 5);
  a = (a + 0xd3a2646c) ^ (a << 9);
  a = (a + 0xfd7046c5) + (a << 3);
  a = (a ^ 0xb55a4f09) ^ (a >> 16);
  return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
  thrust::default_random_engine rng(hash((int)(index * time)));
  thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

  return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3 *arr, float scale) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    glm::vec3 rand = generateRandomVec3(time, index);
    arr[index].x = scale * rand.x;
    arr[index].y = scale * rand.y;
    arr[index].z = scale * rand.z;
  }
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
  numObjects = N;
  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  // LOOK-1.2 - This is basic CUDA memory management and error checking.
  // Don't forget to cudaFree in  Boids::endSimulation.
  cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

  cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

  cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

  // LOOK-1.2 - This is a typical CUDA kernel invocation.
  kernGenerateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects,
    dev_pos, scene_scale);
  checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

  // LOOK-2.1 computing grid params

  // 27 cell check experiment
  float gridCellWidthScale = 2.0f;

#if USE_27_CHECK
  gridCellWidthScale = 1.0f;
#endif

  gridCellWidth = gridCellWidthScale * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
  int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
  gridSideCount = 2 * halfSideCount;

  gridCellCount = gridSideCount * gridSideCount * gridSideCount;
  gridInverseCellWidth = 1.0f / gridCellWidth;
  float halfGridWidth = gridCellWidth * halfSideCount;
  gridMinimum.x -= halfGridWidth;
  gridMinimum.y -= halfGridWidth;
  gridMinimum.z -= halfGridWidth;

  // TODO-2.1 TODO-2.3 - Allocate additional buffers here.
  cudaMalloc((void**)&dev_particleArrayIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleArrayIndices failed!");

  cudaMalloc((void**)&dev_particleGridIndices, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_particleGridIndices failed!");

  cudaMalloc((void**)&dev_gridCellStartIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellStartIndices failed!");

  cudaMalloc((void**)&dev_gridCellEndIndices, gridCellCount * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_gridCellEndIndices failed!");

  cudaMalloc((void**)&dev_pos_sorted, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_pos_sorted failed!");

  cudaMalloc((void**)&dev_vel_sorted, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel_sorted failed!");

  cudaMalloc((void**)&dev_vel_out, N * sizeof(glm::vec3));
  checkCUDAErrorWithLine("cudaMalloc dev_vel_out failed!");

  // Thrust setup
  dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
  dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);

  cudaDeviceSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3 *pos, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  float c_scale = -1.0f / s_scale;

  if (index < N) {
    vbo[4 * index + 0] = pos[index].x * c_scale;
    vbo[4 * index + 1] = pos[index].y * c_scale;
    vbo[4 * index + 2] = pos[index].z * c_scale;
    vbo[4 * index + 3] = 1.0f;
  }
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3 *vel, float *vbo, float s_scale) {
  int index = threadIdx.x + (blockIdx.x * blockDim.x);

  if (index < N) {
    vbo[4 * index + 0] = vel[index].x + 0.3f;
    vbo[4 * index + 1] = vel[index].y + 0.3f;
    vbo[4 * index + 2] = vel[index].z + 0.3f;
    vbo[4 * index + 3] = 1.0f;
  }
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float *vbodptr_positions, float *vbodptr_velocities) {
  dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

  kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_pos, vbodptr_positions, scene_scale);
  kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> >(numObjects, dev_vel1, vbodptr_velocities, scene_scale);

  checkCUDAErrorWithLine("copyBoidsToVBO failed!");

  cudaDeviceSynchronize();
}


/******************
* stepSimulation *
******************/

/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeRule1Velocity(int N, int iSelf, const glm::vec3 *pos)
{
  // Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
  glm::vec3 perceivedCenterOfMass = glm::vec3(0.0f, 0.0f, 0.0f);
  glm::vec3 outVelocity = glm::vec3(0.0f);

  const glm::vec3 selfBoidPosition = pos[iSelf];
  size_t numNeighbors = 0;

  for (size_t i = 0; i < N; i++)
  {
    if (i != iSelf && distance(pos[i], selfBoidPosition) < rule1Distance)
    {
      perceivedCenterOfMass += pos[i];
      numNeighbors++;
    }
  }

  if (numNeighbors > 0)
  {
    perceivedCenterOfMass /= numNeighbors;
    outVelocity = (perceivedCenterOfMass - selfBoidPosition) * rule1Scale;
  }

  return outVelocity;
}

__device__ glm::vec3 computeRule2Velocity(int N, int iSelf, const glm::vec3 *pos)
{
  // Rule 2: boids try to stay a distance d away from each other
  glm::vec3 oppVelocity = glm::vec3(0.0f);

  const glm::vec3 selfBoidPosition = pos[iSelf];

  for (size_t i = 0; i < N; i++)
  {
      // This logic is nearly repeated code, but I think it's fine to separate logic for better clarity.
      if (i != iSelf && distance(pos[i], selfBoidPosition) < rule2Distance)
      {
          oppVelocity -= (pos[i] - selfBoidPosition);
      }
  }

  return oppVelocity * rule2Scale;
}

__device__ glm::vec3 computeRule3Velocity(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel)
{
  // Rule 3: boids try to match the speed of surrounding boids
  glm::vec3 perceivedVelocity = glm::vec3(0.0f);
  glm::vec3 outVelocity = glm::vec3(0.0f);

  const glm::vec3 selfBoidPosition = pos[iSelf];
  size_t numNeighbors = 0;

  for (size_t i = 0; i < N; i++)
  {
      float dist = distance(pos[i], selfBoidPosition);
      if (i != iSelf && dist < rule3Distance)
      {
          perceivedVelocity += vel[i];
          numNeighbors++;
      }
  }

  if (numNeighbors > 0)
  {
    perceivedVelocity /= numNeighbors;
    outVelocity = perceivedVelocity * rule3Scale; 
  }

  return outVelocity;
}


__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3 *pos, const glm::vec3 *vel) {
  glm::vec3 rule1Velocity = computeRule1Velocity(N, iSelf, pos);
  glm::vec3 rule2Velocity = computeRule2Velocity(N, iSelf, pos);
  glm::vec3 rule3Velocity = computeRule3Velocity(N, iSelf, pos, vel);

  return rule1Velocity + rule2Velocity + rule3Velocity;
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3 *pos,
  glm::vec3 *vel1, glm::vec3 *vel2) {
  // Compute a new velocity based on pos and vel1
  // Clamp the speed
  // Record the new velocity into vel2. Question: why NOT vel1?

  // obtain 1D boid ID
  int boidIndex = threadIdx.x + blockIdx.x * blockDim.x;

  if (boidIndex >= N) {
    return;
  }

  glm::vec3 velocityChange = computeVelocityChange(N, boidIndex, pos, vel1);
  glm::vec3 finalVelocity = vel1[boidIndex] + velocityChange;

  // Speed clamp
  if (length(finalVelocity) > maxSpeed)
  {
    finalVelocity = normalize(finalVelocity) * maxSpeed;
  }

  vel2[boidIndex] = finalVelocity;
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3 *pos, glm::vec3 *vel) {
  // Update position by velocity
  int index = threadIdx.x + (blockIdx.x * blockDim.x);
  if (index >= N) {
    return;
  }
  glm::vec3 thisPos = pos[index];
  thisPos += vel[index] * dt;

  // Wrap the boids around so we don't lose them
  thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
  thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
  thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

  thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
  thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
  thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

  pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
  return x + y * gridResolution + z * gridResolution * gridResolution;
}

__global__ void kernComputeIndices(int N, int gridResolution,
  glm::vec3 gridMin, float inverseCellWidth,
  glm::vec3 *pos, int *indices, int *gridIndices) {
  // TODO-2.1
  // - Label each boid with the index of its grid cell.
  // - Set up a parallel array of integer indices as pointers to the actual
  //   boid data in pos and vel1/vel2

  int boidIndex = blockIdx.x * blockDim.x + threadIdx.x;
  if (boidIndex < N)
  {
    // 3D grid approx = (pos - minPos) / cellWidth
    glm::vec3 gridIndex3D = pos[boidIndex];
    gridIndex3D -= gridMin;
    gridIndex3D *= inverseCellWidth;

    int gridIndex = gridIndex3Dto1D(gridIndex3D.x, gridIndex3D.y, gridIndex3D.z, gridResolution);

    gridIndices[boidIndex] = gridIndex;
    indices[boidIndex] = boidIndex;
  }
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int *intBuffer, int value) {
  int index = (blockIdx.x * blockDim.x) + threadIdx.x;
  if (index < N) {
    intBuffer[index] = value;
  }
}

__global__ void kernIdentifyCellStartEnd(int N, int *particleGridIndices,
  int *gridCellStartIndices, int *gridCellEndIndices) {
  // TODO-2.1
  // Identify the start point of each cell in the gridIndices array.
  // This is basically a parallel unrolling of a loop that goes
  // "this index doesn't match the one before it, must be a new cell!"
  int boid = blockIdx.x * blockDim.x + threadIdx.x;

  if (boid < N)
  {
    int gridCell = particleGridIndices[boid];

    if (boid >= 1 && gridCell != particleGridIndices[boid - 1])
    {
      gridCellStartIndices[gridCell] = boid;
    }

    if (boid + 1 < N && gridCell != particleGridIndices[boid + 1])
    {
      gridCellEndIndices[gridCell] = boid;
    }
  }
}

__device__ int positionToGridCell(int gridResolution, glm::vec3 pos, glm::vec3 gridMin, float inverseCellWidth) {
  glm::vec3 gridIndex3D = pos;
  gridIndex3D -= gridMin;
  gridIndex3D *= inverseCellWidth;

  return gridIndex3Dto1D(gridIndex3D.x, gridIndex3D.y, gridIndex3D.z, gridResolution);
}


__global__ void kernUpdateVelNeighborSearchScattered(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  int *particleArrayIndices,
  glm::vec3 *pos, glm::vec3 *vel1, glm::vec3 *vel2) {
  // TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
  // the number of boids that need to be checked.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2

  int boidIndex = blockIdx.x * blockDim.x + threadIdx.x;

  if (boidIndex >= N) {
    return;
  }

  // Accumulated sums/data for our rules
  glm::vec3 rule1Velocity = glm::vec3(0.0f);
  glm::vec3 rule1CenterOfMass = glm::vec3(0.0f);
  int rule1Neighbors = 0;

  glm::vec3 rule2Velocity = glm::vec3(0.0f);

  glm::vec3 rule3PerceivedVelocity = glm::vec3(0.0f);
  int rule3Neighbors = 0;

  // Calculate min/max neighbor cell bounds
  glm::vec3 boidPosition = pos[boidIndex];
  float neighborhoodDistance = imax(rule1Distance, imax(rule2Distance, rule3Distance));

  glm::ivec3 minXYZ, maxXYZ;

#if USE_27_CHECK
  minXYZ = glm::ivec3(-1);
  maxXYZ = glm::ivec3(1);
#else
  minXYZ = (boidPosition - neighborhoodDistance - gridMin) / cellWidth;
  maxXYZ = (boidPosition + neighborhoodDistance - gridMin) / cellWidth;
#endif


  // Mathematically, we only access up to 8 cells
  for (int dz = minXYZ.z; dz <= maxXYZ.z; dz++) {
    for (int dy = minXYZ.y; dy <= maxXYZ.y; dy++) {
      for (int dx = minXYZ.x; dx <= maxXYZ.x; dx++) {
        // Access neighboring grid by min/max cells to check
        int accessedGridCell = gridIndex3Dto1D(dx, dy, dz, gridResolution);
        int startIndex = gridCellStartIndices[accessedGridCell];
        int endIndex = gridCellEndIndices[accessedGridCell];

        // Empty cell, skip
        if (startIndex == -1)
        {
          continue;
        }

        // Iterate through neighbor boids in cell
        for (int neighborBoid = startIndex; neighborBoid <= endIndex; neighborBoid++) {
          int neighborIndex = particleArrayIndices[neighborBoid];

          if (neighborIndex == boidIndex)
          {
            continue;
          }

          glm::vec3 neighborPosition = pos[neighborIndex];
          glm::vec3 currentVelocityChange = glm::vec3(0.0f);

          float distanceToNeighbor = distance(boidPosition, neighborPosition);

          // Ugly repeated code, but get it to work first and refactor later.
          if (distanceToNeighbor < rule1Distance)
          {
            rule1CenterOfMass += neighborPosition;
            rule1Neighbors++;
          }

          if (distanceToNeighbor < rule2Distance)
          {
            rule2Velocity -= (neighborPosition - boidPosition);
          }

          if (distanceToNeighbor < rule3Distance)
          {
            rule3PerceivedVelocity += vel1[neighborIndex];
            rule3Neighbors++;
          }
        }
      }
    }
  }

  if (rule1Neighbors > 0)
  {
    rule1CenterOfMass /= rule1Neighbors;
    rule1Velocity = (rule1CenterOfMass - boidPosition) * rule1Scale;
  }

  rule2Velocity *= rule2Scale;

  if (rule3Neighbors > 0)
  {
    rule3PerceivedVelocity /= rule3Neighbors;
    rule3PerceivedVelocity *= rule3Scale;
  }

  glm::vec3 netVelocityChange = rule1Velocity + rule2Velocity + rule3PerceivedVelocity;
  glm::vec3 finalVelocity = vel1[boidIndex] + netVelocityChange;

  // Speed clamp
  if (length(finalVelocity) > maxSpeed)
  {
      finalVelocity = normalize(finalVelocity) * maxSpeed;
  }

  vel2[boidIndex] = finalVelocity;
}

__global__ void kernUpdateVelNeighborSearchCoherent(
  int N, int gridResolution, glm::vec3 gridMin,
  float inverseCellWidth, float cellWidth,
  int *gridCellStartIndices, int *gridCellEndIndices,
  glm::vec3 *pos_sorted, glm::vec3 *vel_sorted, glm::vec3 *vel_out) {
  // TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
  // except with one less level of indirection.
  // This should expect gridCellStartIndices and gridCellEndIndices to refer
  // directly to pos and vel1.
  // - Identify the grid cell that this particle is in
  // - Identify which cells may contain neighbors. This isn't always 8.
  // - For each cell, read the start/end indices in the boid pointer array.
  //   DIFFERENCE: For best results, consider what order the cells should be
  //   checked in to maximize the memory benefits of reordering the boids data.
  // - Access each boid in the cell and compute velocity change from
  //   the boids rules, if this boid is within the neighborhood distance.
  // - Clamp the speed change before putting the new speed in vel2

  int boidIndex = blockIdx.x * blockDim.x + threadIdx.x;

  if (boidIndex >= N) {
    return;
  }

  // Accumulated sums/data for our rules
  glm::vec3 rule1Velocity = glm::vec3(0.0f);
  glm::vec3 rule1CenterOfMass = glm::vec3(0.0f);
  int rule1Neighbors = 0;

  glm::vec3 rule2Velocity = glm::vec3(0.0f);

  glm::vec3 rule3PerceivedVelocity = glm::vec3(0.0f);
  int rule3Neighbors = 0;

  // Calculate min/max neighbor cell bounds
  glm::vec3 boidPosition = pos_sorted[boidIndex];
  float neighborhoodDistance = imax(rule1Distance, imax(rule2Distance, rule3Distance));

  glm::ivec3 minXYZ = (boidPosition - neighborhoodDistance - gridMin) / cellWidth;
  glm::ivec3 maxXYZ = (boidPosition + neighborhoodDistance - gridMin) / cellWidth;

  // Mathematically, we only access up to 8 cells
  for (int dz = minXYZ.z; dz <= maxXYZ.z; dz++) {
    for (int dy = minXYZ.y; dy <= maxXYZ.y; dy++) {
      for (int dx = minXYZ.x; dx <= maxXYZ.x; dx++) {
        // Access neighboring grid by min/max cells to check
        int accessedGridCell = gridIndex3Dto1D(dx, dy, dz, gridResolution);
        int startIndex = gridCellStartIndices[accessedGridCell];
        int endIndex = gridCellEndIndices[accessedGridCell];

        // Empty cell, skip
        if (startIndex == -1)
        {
          continue;
        }

        // Iterate through neighbor boids in cell
        for (int neighborBoid = startIndex; neighborBoid <= endIndex; neighborBoid++) {
          if (neighborBoid == boidIndex)
          {
            continue;
          }

          glm::vec3 neighborPosition = pos_sorted[neighborBoid];
          glm::vec3 currentVelocityChange = glm::vec3(0.0f);

          float distanceToNeighbor = distance(boidPosition, neighborPosition);

          if (distanceToNeighbor < rule1Distance)
          {
            rule1CenterOfMass += neighborPosition;
            rule1Neighbors++;
          }

          if (distanceToNeighbor < rule2Distance)
          {
            rule2Velocity -= (neighborPosition - boidPosition);
          }

          if (distanceToNeighbor < rule3Distance)
          {
            rule3PerceivedVelocity += vel_sorted[neighborBoid];
            rule3Neighbors++;
          }
        }
      }
    }
  }

  if (rule1Neighbors > 0)
  {
    rule1CenterOfMass /= rule1Neighbors;
    rule1Velocity = (rule1CenterOfMass - boidPosition) * rule1Scale;
  }

  rule2Velocity *= rule2Scale;

  if (rule3Neighbors > 0)
  {
    rule3PerceivedVelocity /= rule3Neighbors;
    rule3PerceivedVelocity *= rule3Scale;
  }

  glm::vec3 netVelocityChange = rule1Velocity + rule2Velocity + rule3PerceivedVelocity;
  glm::vec3 finalVelocity = vel_sorted[boidIndex] + netVelocityChange;

  // Speed clamp
  if (length(finalVelocity) > maxSpeed)
  {
      finalVelocity = normalize(finalVelocity) * maxSpeed;
  }

  vel_out[boidIndex] = finalVelocity;
}

__global__ void kernPopulateSortedPosVel(int N, glm::vec3 *pos_sorted, glm::vec3 *vel_sorted, 
    int *sorted_particleArrayIndices, glm::vec3 *pos, glm::vec3 *vel)
{
  int gridCellIndex = blockIdx.x * blockDim.x + threadIdx.x;

  if (gridCellIndex >= N) {
    return;
  }

  int sortedBoidIndex = sorted_particleArrayIndices[gridCellIndex];
  pos_sorted[gridCellIndex] = pos[sortedBoidIndex];
  vel_sorted[gridCellIndex] = vel[sortedBoidIndex];
}

__global__ void kernRestoreFinalVelocty(int N, glm::vec3 *vel_out_sorted, glm::vec3 *vel2, int *sorted_particleArrayIndices)
{
  int gridCellIndex = blockIdx.x * blockDim.x + threadIdx.x;

  if (gridCellIndex >= N) {
    return;
  }

  int sortedBoidIndex = sorted_particleArrayIndices[gridCellIndex];
  vel2[sortedBoidIndex] = vel_out_sorted[gridCellIndex];
}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
  // blocks = divup(numObjects, blockSize)
  size_t blocks = (numObjects + blockSize - 1) / blockSize;

  // Update boid velocities
  kernUpdateVelocityBruteForce<<<blocks, blockSize>>>(numObjects, dev_pos, dev_vel1, dev_vel2);
  
  // kernUpdatePos() with vel2's data
  kernUpdatePos<<<blocks, blockSize>>>(numObjects, dt, dev_pos, dev_vel2);
  
  // Ping-pong velocity buffers - we need to swap vel1's information with vel2's velocity
  cudaMemcpy(dev_vel1, dev_vel2, sizeof(glm::vec3) * numObjects, cudaMemcpyDeviceToDevice);
}

void Boids::stepSimulationScatteredGrid(float dt) {
  // TODO-2.1
  // Uniform Grid Neighbor search using Thrust sort.
  // In Parallel:
  // - label each particle with its array index as well as its grid index.
  //   Use 2x width grids.
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed

  // Pair boid indices with a grid cell
  // Call kernComputeIndices to label particles with array index + grid index    
  size_t blocks = (numObjects + blockSize - 1) / blockSize;

  // particleArray/Grid data is on GPU
  kernComputeIndices<<<blocks, blockSize>>>(numObjects, gridSideCount, gridMinimum, 
      gridInverseCellWidth, dev_pos, dev_particleArrayIndices, dev_particleGridIndices);

  // Sort on GPU
  thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects, dev_thrust_particleArrayIndices);

  // Reset start/end pointers, this is needed so that we know certain cells have no boids
  size_t cellResetBlocks = (gridCellCount + blockSize - 1) / blockSize;
  kernResetIntBuffer<<<cellResetBlocks, blockSize>>>(gridCellCount, dev_gridCellStartIndices, -1);
  kernResetIntBuffer<<<cellResetBlocks, blockSize>>>(gridCellCount, dev_gridCellEndIndices, -1);

  // By this point, ideally, values in grid are sorted from 0 to gridCellCount - 1
  // Need to now store start and end pointers, this tells us the first index of a boid in gridCellIndex and then the last, "storing" boids in a gridCell
  kernIdentifyCellStartEnd<<<blocks, blockSize>>>(numObjects, dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);

  // Start and end indices of each grid should now be successfully stored. We can now perform velocity updates, ideally
  kernUpdateVelNeighborSearchScattered<<<blocks, blockSize>>>(
      numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, 
      gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices, 
      dev_particleArrayIndices, dev_pos, dev_vel1, dev_vel2);

  // Update pos
  kernUpdatePos<<<blocks, blockSize>>>(numObjects, dt, dev_pos, dev_vel2);
  
  // Ping-pong velocity buffers - we need to swap vel1's information with vel2's velocity
  cudaMemcpy(dev_vel1, dev_vel2, sizeof(glm::vec3) * numObjects, cudaMemcpyDeviceToDevice);
}

void Boids::stepSimulationCoherentGrid(float dt) {
  // TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
  // Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
  // In Parallel:
  // - Label each particle with its array index as well as its grid index.
  //   Use 2x width grids
  // - Unstable key sort using Thrust. A stable sort isn't necessary, but you
  //   are welcome to do a performance comparison.
  // - Naively unroll the loop for finding the start and end indices of each
  //   cell's data pointers in the array of boid indices
  // - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
  //   the particle data in the simulation array.
  //   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
  // - Perform velocity updates using neighbor search
  // - Update positions
  // - Ping-pong buffers as needed. THIS MAY BE DIFFERENT FROM BEFORE.
  size_t blocks = (numObjects + blockSize - 1) / blockSize;

  // particleArray/Grid data is on GPU
  kernComputeIndices<<<blocks, blockSize>>>(numObjects, gridSideCount, gridMinimum, 
      gridInverseCellWidth, dev_pos, dev_particleArrayIndices, dev_particleGridIndices);

  // Sort on GPU, this time include coherent pos/vel that we'll use to directly access
  thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + numObjects, dev_thrust_particleArrayIndices);

  // Populate the "sorted" arrays, though it's just the pos/vel mapped correctly to the sorted array indices
  kernPopulateSortedPosVel<<<blocks, blockSize>>>(numObjects, dev_pos_sorted, dev_vel_sorted, dev_particleArrayIndices, dev_pos, dev_vel1);

  // Reset start/end pointers, this is needed so that we know certain cells have no boids
  size_t cellResetBlocks = (gridCellCount + blockSize - 1) / blockSize;
  kernResetIntBuffer<<<cellResetBlocks, blockSize>>>(gridCellCount, dev_gridCellStartIndices, -1);
  kernResetIntBuffer<<<cellResetBlocks, blockSize>>>(gridCellCount, dev_gridCellEndIndices, -1);

  // By this point, ideally, values in grid are sorted from 0 to gridCellCount - 1
  // Need to now store start and end pointers, this tells us the first index of a boid in gridCellIndex and then the last, "storing" boids in a gridCell
  kernIdentifyCellStartEnd<<<blocks, blockSize>>>(numObjects, dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);

  // Start and end indices of each grid should now be successfully stored. We can now perform velocity updates, ideally
  kernUpdateVelNeighborSearchCoherent<<<blocks, blockSize>>>(
      numObjects, gridSideCount, gridMinimum, gridInverseCellWidth, 
      gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices, 
      dev_pos_sorted, dev_vel_sorted, dev_vel_out);
  
  kernRestoreFinalVelocty<<<blocks, blockSize>>>(numObjects, dev_vel_out, dev_vel2, dev_particleArrayIndices);

  // Update pos
  kernUpdatePos<<<blocks, blockSize>>>(numObjects, dt, dev_pos, dev_vel2);

  // Ping-pong velocity buffers - we need to swap vel1's information with vel2's velocity
  cudaMemcpy(dev_vel1, dev_vel2, sizeof(glm::vec3) * numObjects, cudaMemcpyDeviceToDevice);
}

__global__ void kernUpdateVelNeighborSearchCoherentSharedMem(int N, int *gridIndices_sorted, glm::vec3 *pos_sorted,
    int *gridCellStartIndices, int *gridCellEndIndices)
{
  int index = blockIdx.x * blockDim.x + threadIdx.x;

  if (index >= N) {
    return;
  }
  
  // Populate, for the grid cell the thread is in, its start/end indices in shared memory
  // to avoid global mem lookups later. Idea is that by running our threads on the sorted
  // pos array, other nearby threads may need to access the same cells and therefore start/end indices.
  __shared__ int cellStartEndIndices[sharedGridIndicesSize];

  int minGridCell = gridIndices_sorted[blockIdx.x * blockDim.x];
  int currentSortedGridCell = gridIndices_sorted[index];
  int currentCellStartIndex = gridCellStartIndices[currentSortedGridCell];
  int currentCellEndIndex = gridCellEndIndices[currentSortedGridCell];

  // This guarantees we populate for the first thread index in a cell
  if (index == 0 || gridIndices_sorted[index] != gridIndices_sorted[index - 1])
  {
    int sharedStartEndIndex = 2 * (currentSortedGridCell - minGridCell);
    cellStartEndIndices[sharedStartEndIndex] = currentCellStartIndex;
    cellStartEndIndices[sharedStartEndIndex + 1] = currentCellEndIndex;
  }

  __syncthreads();

  // Now we do the rest of the fun stuff.
  
  // Calculate min/max neighbor cell bounds
  glm::vec3 boidPosition = pos_sorted[boidIndex];
  float neighborhoodDistance = imax(rule1Distance, imax(rule2Distance, rule3Distance));

  glm::ivec3 minXYZ = (boidPosition - neighborhoodDistance - gridMin) / cellWidth;
  glm::ivec3 maxXYZ = (boidPosition + neighborhoodDistance - gridMin) / cellWidth;

  // Mathematically, we only access up to 8 cells
  for (int dz = minXYZ.z; dz <= maxXYZ.z; dz++) {
    for (int dy = minXYZ.y; dy <= maxXYZ.y; dy++) {
      for (int dx = minXYZ.x; dx <= maxXYZ.x; dx++) {
        // Access neighboring grid by min/max cells to check
        int accessedGridCell = gridIndex3Dto1D(dx, dy, dz, gridResolution);
        int startIndex = gridCellStartIndices[accessedGridCell];
        int endIndex = gridCellEndIndices[accessedGridCell];

        // Empty cell, skip
        if (startIndex == -1)
        {
          continue;
        }

        // Iterate through neighbor boids in cell
        for (int neighborBoid = startIndex; neighborBoid <= endIndex; neighborBoid++) {
          if (neighborBoid == boidIndex)
          {
            continue;
          }

          glm::vec3 neighborPosition = pos_sorted[neighborBoid];
          glm::vec3 currentVelocityChange = glm::vec3(0.0f);

          float distanceToNeighbor = distance(boidPosition, neighborPosition);

          if (distanceToNeighbor < rule1Distance)
          {
            rule1CenterOfMass += neighborPosition;
            rule1Neighbors++;
          }

          if (distanceToNeighbor < rule2Distance)
          {
            rule2Velocity -= (neighborPosition - boidPosition);
          }

          if (distanceToNeighbor < rule3Distance)
          {
            rule3PerceivedVelocity += vel_sorted[neighborBoid];
            rule3Neighbors++;
          }
        }
      }
    }
  }
}

void Boids::stepSimulationSharedMemoryGrid(float dt)
{
  // From coherent solution, our pos index is auto sorted based on the min grid cell that exists. If we work under some
  // magical assumption that for thread N, thread N+1 will check N and N+2, and they're contained in the same warp,
  // we can have some time off by storing start/end indices of their cell and similarly other cells they'll access into
  // shared mem.

  // Block size = 128
  
  // compute indices
  // 
  // sort key/value grid cells and boid indices
  // 
  // reset buffers
  // 
  // populate awesome start/end indices
  // 
  // run the stupid neighboring search with shared memory
}

void Boids::endSimulation() {
  cudaFree(dev_vel1);
  cudaFree(dev_vel2);
  cudaFree(dev_pos);

  // TODO-2.1 TODO-2.3 - Free any additional buffers here.
  cudaFree(dev_particleGridIndices);
  cudaFree(dev_particleArrayIndices);
  cudaFree(dev_gridCellStartIndices);
  cudaFree(dev_gridCellEndIndices);

  cudaFree(dev_pos_sorted);
  cudaFree(dev_vel_sorted);
  cudaFree(dev_vel_out);
}

void Boids::unitTest() {
  // LOOK-1.2 Feel free to write additional tests here.

  // test unstable sort
  int *dev_intKeys;
  int *dev_intValues;
  int N = 10;

  std::unique_ptr<int[]>intKeys{ new int[N] };
  std::unique_ptr<int[]>intValues{ new int[N] };

  intKeys[0] = 0; intValues[0] = 0;
  intKeys[1] = 1; intValues[1] = 1;
  intKeys[2] = 0; intValues[2] = 2;
  intKeys[3] = 3; intValues[3] = 3;
  intKeys[4] = 0; intValues[4] = 4;
  intKeys[5] = 2; intValues[5] = 5;
  intKeys[6] = 2; intValues[6] = 6;
  intKeys[7] = 0; intValues[7] = 7;
  intKeys[8] = 5; intValues[8] = 8;
  intKeys[9] = 6; intValues[9] = 9;

  cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

  cudaMalloc((void**)&dev_intValues, N * sizeof(int));
  checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

  dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

  std::cout << "before unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // How to copy data to the GPU
  cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
  cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N, cudaMemcpyHostToDevice);

  // Wrap device vectors in thrust iterators for use with thrust.
  thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
  thrust::device_ptr<int> dev_thrust_values(dev_intValues);
  // LOOK-2.1 Example for using thrust::sort_by_key
  thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

  // How to copy data back to the CPU side from the GPU
  cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
  cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
  checkCUDAErrorWithLine("memcpy back failed!");

  std::cout << "after unstable sort: " << std::endl;
  for (int i = 0; i < N; i++) {
    std::cout << "  key: " << intKeys[i];
    std::cout << " value: " << intValues[i] << std::endl;
  }

  // cleanup
  cudaFree(dev_intKeys);
  cudaFree(dev_intValues);
  checkCUDAErrorWithLine("cudaFree failed!");
  return;
}