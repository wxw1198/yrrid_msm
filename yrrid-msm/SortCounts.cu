/***

Copyright (c) 2022, Yrrid Software, Inc.  All rights reserved.
Licensed under the Apache License, Version 2.0, see LICENSE for details.

Written by Niall Emmart.

***/


__global__ void histogramPrefixSumKernel(void* histogramPtr, void* unsortedTriplePtr) {
  uint32_t  globalTID=blockIdx.x*blockDim.x+threadIdx.x, globalStride=gridDim.x*blockDim.x;
  uint32_t* histogram=(uint32_t*)histogramPtr;
  uint32_t* counts=(uint32_t*)unsortedTriplePtr;
  uint32_t  count, localSum;
  uint32_t  i;
  
  __shared__ uint32_t sharedHistogram[1024];
  __shared__ uint32_t warpTotals[32];
  
  // must launch with 1024 threads
  
  sharedHistogram[threadIdx.x]=0;

  __syncthreads();
    
  #pragma unroll 1
  for(i=globalTID;i<NBUCKETS;i+=globalStride) {//0 2 4 6 8 10 windows
    count=0;
    #pragma unroll
    for(int32_t j=0;j<=10*NBUCKETS;j+=2*NBUCKETS) 
      count+=counts[j + i];
    count=umin(count, 1023);
//      printf("histogramPrefixSumKernel, count:%d\n",count);
    atomicAdd(&sharedHistogram[1023-count], 1);
  }
  
  #pragma unroll 1
  for(;i<2*NBUCKETS;i+=globalStride) {//1 3 5 7 windows
    count=0;
    #pragma unroll
    for(int32_t j=0;j<=8*NBUCKETS;j+=2*NBUCKETS) 
      count+=counts[j + i];
    count=umin(count, 1023);
//      printf("histogramPrefixSumKernel, count:%d\n",count);
      atomicAdd(&sharedHistogram[1023-count], 1);
  }
  
  __syncthreads();

  count=sharedHistogram[threadIdx.x];
  localSum=multiwarpPrefixSum(warpTotals, count, 32);
//  printf("localsum:%d, count:%d\n", localSum, count);
  atomicAdd(&histogram[threadIdx.x], localSum-count);//record 每个级别的count 有多少个；先在histogram做记录,做好空间预留
}

__global__ void sortCountsKernel(void* sortedTriplePtr, void* histogramPtr, void* unsortedTriplePtr) {
  uint32_t  globalTID=blockIdx.x*blockDim.x+threadIdx.x, globalStride=gridDim.x*blockDim.x;
  uint32_t  warp=threadIdx.x>>5, warpThread=threadIdx.x & 0x1F, warps=blockDim.x>>5;
  uint32_t* histogram=(uint32_t*)histogramPtr;
  
  uint32_t  counts[6], indexes[6];
  uint32_t  count, bin, binCount, writeIndex, mask, thread, localWriteIndex, localBin, localBucket;
  bool      processed;

  // input pointers
  uint32_t* unsortedCounts=(uint32_t*)unsortedTriplePtr;
  uint32_t* unsortedIndexes=((uint32_t*)unsortedTriplePtr) + NBUCKETS*11;
  
  // output pointers
  uint32_t* sortedBuckets=(uint32_t*)sortedTriplePtr; //包含两个窗口（NBUCKETS）的点
  uint4*    sortedCountsAndIndexes=(uint4*)(sortedBuckets + NBUCKETS*2 + 32);
  //uint32_t* sortedCounts=((uint32_t*)sortedTriplePtr) + NBUCKETS*2 + 32;
  //uint32_t* sortedIndexes=((uint32_t*)sortedTriplePtr) + NBUCKETS*14 + 32*7;
  
  extern __shared__ uint32_t shmem[];
  
  uint32_t* binCounts=shmem;                         // 1*256 (words)  1kb
  uint32_t* buckets=shmem+256;                       // 7*256 (words)  7kb
  uint4*    countsAndIndexes=(uint4*)(shmem+8*256);  // 7*12*256       84kb

  if(globalTID<384) {
    // 32 empty entries
    if(globalTID<32)
      sortedBuckets[NBUCKETS*2 + globalTID]=NBUCKETS*2 + globalTID;

    // 32*12 words: counts and indexes
    sortedBuckets[NBUCKETS*26 + globalTID + 32]=0;
  }

  for(int32_t i=threadIdx.x;i<256;i+=blockDim.x) 
    binCounts[i]=0;
  
  for(int32_t i=threadIdx.x;i<7*256;i+=blockDim.x) 
    buckets[i]=0xFFFFFFFF;
    
  __syncthreads();
  
  #pragma unroll 1
  for(uint32_t bucket=globalTID;bucket<2*NBUCKETS;bucket+=globalStride) {
    // collect the data
    if(bucket<NBUCKETS) {
      count=0;
      #pragma unroll
      for(int32_t i=0;i<6;i++) {//0 2 4 6 8 10
        counts[i]=unsortedCounts[NBUCKETS*2*i + bucket];
        indexes[i]=unsortedIndexes[NBUCKETS*2*i + bucket];
        count+=counts[i];
      }
    }
    else {
      count=0;
      #pragma unroll
      for(int32_t i=0;i<5;i++) { // 1 3 5 7 9
        counts[i]=unsortedCounts[NBUCKETS*2*i + bucket];
        indexes[i]=unsortedIndexes[NBUCKETS*2*i + bucket];
        count+=counts[i];
      }
      counts[5]=0;
      indexes[5]=0;
    }
    
    processed=count>255;
//    if (count <= 6)
//      printf("count:%d \n", count);

      // if we have a lot of points in the coalesced bucket, do special one-off processing
    if(processed) {
      bin=umax(count, 1023);//2^26个点，分到2^22窗口中，每个窗口最多2^4;6个相同位置聚合，2^4*6=96，count平均96个左右
      printf("count:%d, bin:%d\n", count, bin);

        writeIndex=atomicAdd(&histogram[1023-bin], 1);
      sortedBuckets[writeIndex]=bucket;
      #pragma unroll
      for(int i=0;i<3;i++)
        sortedCountsAndIndexes[writeIndex*3 + i]=make_uint4(counts[i*2 + 0], indexes[i*2 + 0], counts[i*2 + 1], indexes[i*2 + 1]);
    }
    
    // we don't have so many points in the coalesced bucket, use sh mem processing
    bin=count;
    binCount=0;
    while(!__all_sync(0xFFFFFFFF, processed)) {
      if(!processed) {
        binCount=atomicAdd(&binCounts[bin], 1);
        if(binCount<7) {
          countsAndIndexes[bin*7*3 + binCount*3 + 0]=make_uint4(counts[0], indexes[0], counts[1], indexes[1]);
          countsAndIndexes[bin*7*3 + binCount*3 + 1]=make_uint4(counts[2], indexes[2], counts[3], indexes[3]);
          countsAndIndexes[bin*7*3 + binCount*3 + 2]=make_uint4(counts[4], indexes[4], counts[5], indexes[5]);
          buckets[bin*7 + binCount]=bucket;//归入到两个窗口
          processed=true;
        }
      }
      if(binCount==6) {
          writeIndex = atomicAdd(&histogram[1023 - bin], 7);//6个共享内存 中的，空槽被使用完毕
          printf("writeIndex:%d, bin:%d\n", writeIndex, bin);
      }
      while(true) {
        mask=__ballot_sync(0xFFFFFFFF, binCount==6);
        if(mask==0)
          break;// all return 0, binCount!=6
        thread=31-__clz(mask);//第thread个线程对应的binCount=6,则同步次线程数据
        localBin=__shfl_sync(0xFFFFFFFF, bin, thread);//广播threadd(offset)对应的线程中的bin
        localWriteIndex=__shfl_sync(0xFFFFFFFF, writeIndex, thread);
//          printf("local writeIndex:%d, bin:%d\n", localWriteIndex, localBin);

          if(warpThread<7) {//localBin max is 255, warpThread0~7,warpThread不能超过7
          localBucket=atomicExch(&buckets[localBin*7 + warpThread], 0xFFFFFFFF);
          while(localBucket==0xFFFFFFFF)//wait other warp
            localBucket=atomicExch(&buckets[localBin*7 + warpThread], 0xFFFFFFFF);
          sortedBuckets[localWriteIndex + warpThread]=localBucket;//每个线程，完成了自己的排序工作
        }
        __syncwarp(0xFFFFFFFF);
        if(warpThread<21) // warpThread大于21时，没有对应的countsAandIndexes
          sortedCountsAndIndexes[localWriteIndex*3 + warpThread]=countsAndIndexes[localBin*7*3 + warpThread];
        __syncwarp(0xFFFFFFFF);
        binCounts[localBin]=0;
        binCount=(thread==warpThread) ? 0 : binCount;
      }
    }
  }
  
  __syncthreads();

  for(int32_t i=warp;i<256;i+=warps) {
    binCount=binCounts[i];
    if(binCount>0) {
      if(warpThread==0) {
          writeIndex = atomicAdd(&histogram[1023 - i], binCount);
//          printf("writeIndex:%d, bin:%d\n", writeIndex, binCount);
      }
      writeIndex=__shfl_sync(0xFFFFFFFF, writeIndex, 0);
      if(warpThread<binCount) 
        sortedBuckets[writeIndex + warpThread]=buckets[i*7 + warpThread];
      if(warpThread<binCount*3) 
        sortedCountsAndIndexes[writeIndex*3 + warpThread]=countsAndIndexes[i*7*3 + warpThread];
    }
  }
}
