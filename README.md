**University of Pennsylvania, CIS 5650: GPU Programming and Architecture,
Project 1 - Flocking**

* Anthony Ge
  * [LinkedIn](https://www.linkedin.com/in/anthonyge/), [personal website](geant.pro)
* Tested on: Windows 11, i9-13900H @ 2600 Mhz 16GB, NVIDIA GeForce RTX 4070 Laptop GPU 8GB

### (TODO: Your README)

Include screenshots, analysis, etc. (Remember, this is public, so don't put
anything here that you don't want to share with the world.)

# Part 3: Performance Analysis
## Performance Measuring
To gather FPS data, I logged the number of frames rendered over a 10 second period using data from glfw. Depending on whether or not I want to measure kernel performance from NSight Compute, I also have a preprocessor directive for toggling a frame limit before automatically terminating the boids program. 

This average FPS data is then logged to stdout. The rough pseudocode is as such for general purpose FPS logging.

```
double initTime = glfwGetTime()
double currentTime = initTime
int framesCollected = 0

while (application should run .. AND (currentTime - initTime) < 10 seconds)
{
  currentTime = glfwGetTime()
  framesCollected++

  .. run loop
}

// Alternatively, if profiling for NSight Compute, have while loop break if framesCollected > 5 to ensure consistent kernels logged.

print(avg FPS: framesCollectedd / 10)
```

Data was then collected and logged in a spreadsheet, detailing performance vs. boid size, block size, and whether or not we're rendering boids.

## Questions:
#### For each implementation, how does changing the number of boids affect performance, why do you think that is?

![avg fps vs number of boids, viz on](images/FPSBoidNumVizOff.png)
![avg fps vs number of boids, viz off](images/FPSBoidNumVizON.png)

Generally across all three methods of implementation, the performance decreased as number of boids increased. The simplest explanation is that increasing boid count requires us to process more boids by using more threads, and in doing so this also requires us to allocate more device memory. 

Each thread will also have more work by needing to process other boids, which is increased. Therefore, each thread does more work too. This is particularly harmful for the **Naive implementation** since each thread needs to check O(n) boids, which scales very poorly. Thus, naive scales like a curve.

**For Coherent/Uniform,** the performance drop isn't as dramatic as the naive because we check a constant number of cells, but per cell the number of boids is still generally larger.

Depending on whether or not the number of boids is a multiple of our block size, this can impact the number of blocks ran too. 

Since increasing the number of boids means we need to render more objects, we can see lower performance for visualize on versus off.

#### For each implementation, how does changing the block count and block size affect performance? Why do you think this is?
![avg fps vs block size, viz off](images/FPSBlockSizeVizOFF.png)
Block size seemed generally improved performance as we increased count from 1-32 across all methods of implementation, but overall flattened for uniform and naive. Coherent, on the otherhand, seemed to perform just a little bit better as we increased block size past 32, but more importantly its rate of improvement paled by comparison to 1-32.

This can be attributed to the 32 thread warp size on our GPU cards, as warp sizes in multiples of 32 will perform similarly since each block won't have any unutilized threads. This is noted as well with our block size of 16, where many threads are under-utilized, showing the performance hit in naive and coherent (though somehow uniform did better across multiple tests...).

#### Did you experience any performance improvements with the more coherent uniform grid? Was this the outcome you expected? Why or why not?

The performance improvements for coherent were very clear as our boid count increased. Across all tests for boid size, coherent always performed better than uniform.

I did expect an improvement in performance, but I did not think it would be this significant, as I figured reducing 2 memory reads can only do so much, and because of the overhead of reshuffling our buffers. 

However, I was very wrong! While reducing two memory reads per neighbor check to find indices can be helpful, I think the more important improvement comes from the contiguous memory in cache when we do access pos/vel data per boid in a grid. This therefore results in better cache coherency and hits, unlike the previous model where indexing into unordered pos/vel will be in random positions of our 1D buffers, which definitely scales horribly. 

The performance gains from better cache usage significantly overpowers the overhead from running a kernel to reshuffle our buffers. **Checking NSight Compute,** we can actually see the difference in throughput:

**For uniform, observe the screenshots analyzing kernel duration and L1/L2 cycles:**
![uniformPerf](images/uniformPerf.png)
![uniformCachePerf](images/uniformCacheCycles.png)
Through the screenshots, we can see kernel ```kernUpdateVelNeighborSearchScattered``` run for 947us, which is ~1ms. This is for our uniform implmentation without any reshuffling and middle-man cuts. Our L2 and L1 cache cycles are also high in the millions.

**Upon switching to coherent, our overall kernel durations and L1/L2 cycles are significantly lower, even though we practically changed nothing in the coherent neighbor kernel code!**
![coherentPerf](images/coherentPerf.png)
![coherentCachePerf](images/coherentCacheCycles.png)
Average L2 Active Cycles reduced by ~6.36x, which is an incredible improvement. Our L1 cycles have also been reduced, most likely due to better cache performance from our reshuffled buffers.

We can easily see that the combined ```34.82us + 162.69us``` cost is significantly cheaper than ```947.04us```, meaning our reshuffling kernel is well worth the additional overhead.



