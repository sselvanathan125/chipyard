package chipyard

import org.chipsalliance.cde.config.{Config}


class SOCwithGemminiVDP extends Config(
  new chipyard.example.WithGCD ++       // our custom accelerator
  new gemmini.DefaultGemminiConfig ++                            // use Gemmini systolic array GEMM accelerator
  new chipyard.config.WithSystemBusWidth(128) ++    // bus width
  new freechips.rocketchip.rocket.WithNBigCores(1) ++
  new chipyard.config.AbstractConfig
)

/*

class  SOCwithGemminiVDP extends Config(
 
  new gemmini.DefaultGemminiConfig ++   
  new chipyard.example.WithGCD(
    dmaWriteBase = Some(0x80200000L), // Sets the address for the DMA write-back
    dmaReadEnable = true             // Enables the DMA for loading input data
  ) ++
  new chipyard.config.WithSystemBusWidth(128) ++
  new freechips.rocketchip.rocket.WithNBigCores(1) ++
  new chipyard.config.AbstractConfig
)


class GemminiRocketSoC extends Config(
  new gemmini.DefaultGemminiConfig ++                            // use Gemmini systolic array GEMM accelerator
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.WithSystemBusWidth(128) ++
  new chipyard.config.AbstractConfig)

*/