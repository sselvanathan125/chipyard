/*package chipyard.example

import sys.process._

import chisel3._
import chisel3.util._
import chisel3.experimental._
import freechips.rocketchip.amba.axi4._
import freechips.rocketchip.prci._
import freechips.rocketchip.subsystem._
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.regmapper._
import freechips.rocketchip.tilelink._
import freechips.rocketchip.util._
import freechips.rocketchip.subsystem._
import testchipip.soc._


// SimpleDMABlackBox: Defines the Chisel interface for the Verilog SimpleDMA module.
// It also specifies the path to the Verilog source file.
class SimpleDMABlackBox extends BlackBox with HasBlackBoxResource {
  val io = IO(new Bundle {
    val clk         = Input(Clock())
    val rst         = Input(Bool())
    val start       = Input(Bool())
    val src_addr    = Input(UInt(32.W))
    val dst_addr    = Input(UInt(32.W))
    val len         = Input(UInt(8.W))
    val done        = Output(Bool())

    // Memory read request channel (from DMA to memory)
    val req_valid   = Output(Bool())
    val req_addr    = Output(UInt(32.W))
    val req_ready   = Input(Bool()) // Memory is ready for the request
    val resp_data   = Input(UInt(32.W)) // Data comes back from memory
    val resp_valid  = Input(Bool())  // The memory response data is valid

    // Memory write channel (from DMA to memory)
    val write_valid = Output(Bool())
    val write_addr  = Output(UInt(32.W))
    val write_data  = Output(UInt(32.W))
    val write_ready = Input(Bool()) // Memory is ready for the write
  })
  // Specifies the path to the Verilog source file.
  // This file should be located at chipyard/src/main/resources/vsrc/SimpleDMA.v
  addResource("/vsrc/SimpleDMA.v")
}

// SimpleDMATL: A Chisel LazyModule that wraps the SimpleDMABlackBox and integrates it
// into the TileLink (TL) bus fabric. It provides a control interface and a memory master interface.
class SimpleDMATL(implicit p: Parameters) extends LazyModule {
  // controlNode: This is a TLRegisterNode that provides a memory-mapped interface
  // for software to control the DMA. It acts as a slave on the peripheral bus (PBUS).
  val controlNode = TLRegisterNode(
    address = Seq(AddressSet(0x10012000, 0xfff)), // Base address and size of the register space
    device = new SimpleDevice("simple-dma-controller", Seq("ucb-bar,simple-dma")), // Device description
    beatBytes = 4) // Data width for register access

  // dmaNode: This is a TLClientNode that allows the DMA to initiate memory transactions.
  // It acts as a master on the system bus (SBUS).
  val dmaNode = TLClientNode(Seq(TLClientPortParameters(Seq(TLClientParameters(
    name = "simple-dma",
    sourceId = IdRange(0, 1)))))) // Defines the master's capabilities (e.g., source IDs)

  // lazy val module: The actual Chisel module implementation.
  lazy val module = new LazyModuleImp(this) {
    val dma = Module(new SimpleDMABlackBox) // Instantiate the black box module

    // Get the TileLink bundle from the dmaNode's output.
    // 'out' is the TLBundle, 'edge' provides information about the connected bus.
    val (out, edge) = dmaNode.out(0)

    // Control registers: These Chisel registers will be mapped to memory addresses
    // accessible by the CPU via the controlNode.
    val start_reg    = RegInit(0.U(1.W)) // Use RegInit for explicit reset value
    val done_reg     = RegInit(0.U(1.W)) // Done signal from DMA, read by CPU
    val src_addr_reg = RegInit(0.U(32.W))
    val dst_addr_reg = RegInit(0.U(32.W))
    val len_reg      = RegInit(0.U(8.W))

    // Register map for controlNode: Defines how the control registers are exposed
    // to the TileLink bus.
    controlNode.regmap(
      0x00 -> Seq(RegField.w(1, start_reg, RegFieldDesc("start", "Start DMA transfer"))),
      0x08 -> Seq(RegField.r(1, done_reg,  RegFieldDesc("done", "DMA transfer complete"))),
      0x10 -> Seq(RegField.w(32, src_addr_reg, RegFieldDesc("src_addr", "Source address"))),
      0x18 -> Seq(RegField.w(32, dst_addr_reg, RegFieldDesc("dst_addr", "Destination address"))),
      0x20 -> Seq(RegField.w(8, len_reg, RegFieldDesc("len", "Transfer length"))))

    // Connect control registers to BlackBox IO:
    // These connections pass the values from the Chisel registers to the BlackBox inputs.
    dma.io.clk       := clock
    dma.io.rst       := reset.asBool
    dma.io.start     := start_reg(0) // Assuming start_reg is 1-bit for the blackbox
    dma.io.src_addr  := src_addr_reg
    dma.io.dst_addr  := dst_addr_reg
    dma.io.len       := len_reg
    done_reg         := dma.io.done // Capture the done signal from the blackbox

    // --- DMA memory access handling ---
    // Arbiter for read and write requests on a single TL channel:
    // The DMA black box has separate read and write request channels,
    // but the TileLink master port (dmaNode) is a single channel for all A-type messages.
    // An arbiter is used to multiplex read and write requests onto this single TL channel.
    val arb = Module(new Arbiter(new TLBundleA(edge.bundle), 2))
    out.a <> arb.io.out // Connect the arbiter output to the TL A-channel

    // Read requests (port 0 of the arbiter):
    // Convert the DMA's read request to a TileLink Get message.
    arb.io.in(0).valid := dma.io.req_valid
    // edge.Get creates a TL Get message. 0.U is the source ID, dma.io.req_addr is the address,
    // log2Ceil(4).U indicates a 4-byte (word) access.
    arb.io.in(0).bits  := edge.Get(0.U, dma.io.req_addr, log2Ceil(4).U)._2
    val read_fire = arb.io.in(0).fire // 'fire' indicates when the transaction actually occurs

    // Write requests (port 1 of the arbiter):
    // Convert the DMA's write request to a TileLink PutFullData message.
    arb.io.in(1).valid := dma.io.write_valid
    // edge.Put creates a TL PutFullData message.
    arb.io.in(1).bits  := edge.Put(0.U, dma.io.write_addr, log2Ceil(4).U, dma.io.write_data)._2
    val write_fire = arb.io.in(1).fire // 'fire' indicates when the transaction actually occurs

    // Connect ready signals back to DMA BlackBox:
    // The DMA black box needs to know when its requests are accepted by the bus.
    dma.io.req_ready   := read_fire
    dma.io.write_ready := write_fire

    // Always ready to accept responses on the D-channel:
    // The D-channel carries responses (e.g., read data). The DMA is always ready to receive them.
    out.d.ready := true.B

    // Response signals to DMA BlackBox:
    // Extract the valid data and valid signal from the TL D-channel for the DMA.
    dma.io.resp_valid := out.d.valid && out.d.bits.opcode === TLMessages.AccessAckData
    dma.io.resp_data  := out.d.bits.data
  }
}

// DMAKey: A Chisel Field to hold the parameters for the SimpleDMA module.
case object DMAKey extends Field[Option[DMAParams]](None)
case class DMAParams(address: BigInt = 0x10012000L) // Default address for the DMA's control registers

// DMAInjector: A SubsystemInjector that adds the SimpleDMA to the Chipyard SoC.
// This is the mechanism that connects the DMA's LazyModule to the main buses.
case object DMAInjector extends SubsystemInjector((p, baseSubsystem) => {
  // Check if DMAKey is present in the parameters, indicating the DMA should be included.
  p(DMAKey).foreach { params =>
    implicit val q: Parameters = p // Propagate parameters

    // Locate the System Bus (SBUS) and Peripheral Bus (PBUS) from the base subsystem.
    val sbus = baseSubsystem.locateTLBusWrapper(SBUS)
    val pbus = baseSubsystem.locateTLBusWrapper(PBUS)

    // Generate a synchronous domain for the DMA. This ensures the DMA operates
    // on its own clock and reset, derived from the SBUS.
    val dmaDomain = sbus.generateSynchronousDomain
    dmaDomain {
      val dma = LazyModule(new SimpleDMATL()(p)) // Instantiate the SimpleDMATL LazyModule

      // Connect the DMA's controlNode (slave) to the Peripheral Bus (PBUS).
      // TLFragmenter handles potential byte-lane mismatches between the PBUS and the DMA.
      pbus.coupleTo("simple-dma-control") {
        dma.controlNode := TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
      }
      // Connect the DMA's dmaNode (master) to the System Bus (SBUS).
      // TLBuffer adds optional buffering for performance.
      sbus.coupleFrom("simple-dma-mem") {
        _ := TLBuffer() := dma.dmaNode
      }
    }
  }
})

// WithSimpleDMA: A Config fragment that sets the DMAKey, enabling the DMAInjector.
// This config should be mixed into your desired SoC configuration.
class WithSimpleDMA(address: BigInt = 0x10012000L) extends Config((site, here, up) => {
  case DMAKey => Some(DMAParams(address))
})

*/