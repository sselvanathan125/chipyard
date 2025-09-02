package chipyard

import org.chipsalliance.cde.config.{Config}

class DualGemminiRocketConfig extends Config(
  new gemmini.DefaultGemminiConfig ++              // Add the first Gemmini (gets custom0)
  new gemmini.DefaultGemminiConfig ++              // Add the second Gemmini (gets custom1)
  new freechips.rocketchip.rocket.WithNBigCores(1) ++
  new chipyard.config.AbstractConfig)