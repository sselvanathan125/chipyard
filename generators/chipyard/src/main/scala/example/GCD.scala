package chipyard.example

import sys.process._

import chisel3._
import chisel3.util._
import chisel3.experimental.{IntParam, BaseModule}
import freechips.rocketchip.amba.axi4._
import freechips.rocketchip.prci._
import freechips.rocketchip.subsystem.{BaseSubsystem, PBUS}
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.regmapper.{HasRegMap, RegField, RegFieldDesc}
import freechips.rocketchip.tilelink._
import freechips.rocketchip.util._

// DOC include start: GCD params
case class GCDParams(
  address: BigInt = 0x4000,
  width: Int = 32,
  useAXI4: Boolean = false,
  useBlackBox: Boolean = true,
  useHLS: Boolean = false,
  externallyClocked: Boolean = false
) {
  require(!(useAXI4 && useHLS))
}
// DOC include end: GCD params


// DOC include start: GCD key
case object GCDKey extends Field[Option[GCDParams]](None)
// DOC include end: GCD key

// Modified GCDIO to remove extra data inputs
class GCDIO(val w: Int) extends Bundle {
  val clock = Input(Clock())
  val reset = Input(Bool())
  val input_ready = Output(Bool())
  val input_valid = Input(Bool())
  val ax = Input(UInt(w.W))
  val output_ready = Input(Bool())
  val output_valid = Output(Bool())
  val res = Output(UInt((2 * w).W))
  val dp_read_addr = Input(UInt(6.W))

  val mem_addr = Input(UInt(log2Ceil(192).W))
  val mem_write_data = Input(UInt(w.W))
  val mem_write_en = Input(Bool())
  val load_count = Output(UInt(6.W))
  val busy = Output(Bool())
}

class HLSGCDAccelIO(val w: Int) extends Bundle {
  val ap_clk = Input(Clock())
  val ap_rst = Input(Reset())
  val ap_start = Input(Bool())
  val ap_done = Output(Bool())
  val ap_idle = Output(Bool())
  val ap_ready = Output(Bool())
  val ax = Input(UInt(w.W))
  val ap_return = Output(UInt((2 * w).W))
}

class GCDTopIO extends Bundle {
  val gcd_busy = Output(Bool())
}

trait HasGCDTopIO {
  def io: GCDTopIO
}

// DOC include start: GCD blackbox
class GCDMMIOBlackBox(val w: Int) extends BlackBox(Map("WIDTH" -> IntParam(w))) with HasBlackBoxResource {
  val io = IO(new GCDIO(w))
  addResource("/vsrc/GCDMMIOBlackBox.v")
}
// DOC include end: GCD blackbox

// DOC include start: GCD chisel
// This Chisel module is a placeholder, the logic is simplified to pass 'ax' through
class GCDMMIOChiselModule(val w: Int) extends Module {
  val io = IO(new GCDIO(w))
  val s_idle :: s_done :: Nil = Enum(2)

  val state = RegInit(s_idle)
  val res_reg = Reg(UInt((2*w).W))

  io.input_ready := state === s_idle
  io.output_valid := state === s_done
  io.res := res_reg

  // Dummy connections for other ports
  io.mem_addr := 0.U
  io.mem_write_data := 0.U
  io.mem_write_en := false.B
  io.load_count := 0.U

  when (state === s_idle && io.input_valid) {
    state := s_done
    res_reg := io.ax // Pass input 'ax' to result register
  } .elsewhen (state === s_done && io.output_ready) {
    state := s_idle
  }

  io.busy := state =/= s_idle
}
// DOC include end: GCD chisel

// DOC include start: HLS blackbox
class HLSGCDAccelBlackBox(val w: Int) extends BlackBox with HasBlackBoxPath {
  val io = IO(new HLSGCDAccelIO(w))

  val chipyardDir = System.getProperty("user.dir")
  val hlsDir = s"$chipyardDir/generators/chipyard"

  // Run HLS command
  val make = s"make -C ${hlsDir}/src/main/resources/hls default"
  require (make.! == 0, "Failed to run HLS")

  // Add each vlog file
  addPath(s"$hlsDir/src/main/resources/vsrc/HLSGCDAccelBlackBox.v")
  addPath(s"$hlsDir/src/main/resources/vsrc/HLSGCDAccelBlackBox_flow_control_loop_pipe.v")
}
// DOC include end: HLS blackbox

// DOC include start: GCD router
class GCDTL(params: GCDParams, beatBytes: Int)(implicit p: Parameters) extends ClockSinkDomain(ClockSinkParameters())(p) {
  val device = new SimpleDevice("gcd", Seq("ucbbar,gcd"))
  val node = TLRegisterNode(Seq(AddressSet(params.address, 4096-1)), device, "reg/control", beatBytes=beatBytes)

  override lazy val module = new GCDImpl
  class GCDImpl extends Impl with HasGCDTopIO {
    val io = IO(new GCDTopIO)
    withClockAndReset(clock, reset) {
      val ax = Wire(new DecoupledIO(UInt(params.width.W)))
      val res = Wire(new DecoupledIO(UInt((2 * params.width).W)))
      val dp_read_addr_reg = Reg(UInt(6.W))
      val mem_addr_reg = Reg(UInt(log2Ceil(192).W))
      val mem_write_data_reg = Reg(UInt(params.width.W))
      val mem_write_en_reg = RegInit(false.B)
      val load_count_wire = Wire(new DecoupledIO(UInt(6.W)))

      val impl_io = Module(new GCDMMIOBlackBox(params.width)).io
      impl_io.clock := clock
      impl_io.reset := reset.asBool
      val status = Cat(impl_io.input_ready, impl_io.output_valid)
      
      // Connect input, valid is triggered by write to 'ax' register
      impl_io.ax := ax.bits
      impl_io.input_valid := ax.valid
      ax.ready := impl_io.input_ready

      impl_io.dp_read_addr := dp_read_addr_reg

      res.bits := impl_io.res
      res.valid := impl_io.output_valid
      impl_io.output_ready := res.ready

      io.gcd_busy := impl_io.busy
      impl_io.mem_addr := mem_addr_reg
      impl_io.mem_write_data := mem_write_data_reg
      impl_io.mem_write_en := mem_write_en_reg
      load_count_wire.bits := impl_io.load_count
      load_count_wire.valid := true.B

      when (mem_write_en_reg) {
        mem_write_en_reg := false.B
      }

      // Define the memory map
      node.regmap(
        0x00 -> Seq(RegField.r(2, status)),
        0x04 -> Seq(RegField.w(params.width, ax)),
        0x08 -> Seq(RegField.r((2 * params.width), res)),
        // Assuming 32-bit width, res is 64-bit and takes up 0x08 and 0x0C
        0x10 -> Seq(RegField.r(6, load_count_wire)),
        0x14 -> Seq(RegField.w(log2Ceil(192), mem_addr_reg)),
        0x18 -> Seq(RegField.w(params.width, mem_write_data_reg)),
        0x1C -> Seq(RegField.w(1, mem_write_en_reg)),
        0x20 -> Seq(RegField.w(6, dp_read_addr_reg, RegFieldDesc("dp_read_addr", "Address (0-33) of DP result to read via 'res' port.")))
      )
    }
  }
}



class GCDAXI4(params: GCDParams, beatBytes: Int)(implicit p: Parameters) extends ClockSinkDomain(ClockSinkParameters())(p) {
  val node = AXI4RegisterNode(AddressSet(params.address, 4096-1), beatBytes=beatBytes)
  override lazy val module = new GCDImpl
  class GCDImpl extends Impl with HasGCDTopIO {
    val io = IO(new GCDTopIO)
    withClockAndReset(clock, reset) {
      val ax = Wire(new DecoupledIO(UInt(params.width.W)))
      val res = Wire(new DecoupledIO(UInt((2 * params.width).W)))

      val mem_addr_reg = Reg(UInt(log2Ceil(192).W))
      val mem_write_data_reg = Reg(UInt(params.width.W))
      val mem_write_en_reg = RegInit(false.B)
      val dp_read_addr_reg = Reg(UInt(6.W))
      val load_count_wire = Wire(new DecoupledIO(UInt(log2Ceil(33).W)))

      val impl_io = if (params.useBlackBox) {
        Module(new GCDMMIOBlackBox(params.width)).io
      } else {
        Module(new GCDMMIOChiselModule(params.width)).io
      }

      impl_io.clock := clock
      impl_io.reset := reset.asBool

      val status = Cat(impl_io.input_ready, impl_io.output_valid)

      impl_io.ax := ax.bits
      impl_io.input_valid := ax.valid
      ax.ready := impl_io.input_ready

      res.bits := impl_io.res
      res.valid := impl_io.output_valid
      impl_io.output_ready := res.ready

      io.gcd_busy := impl_io.busy

      impl_io.dp_read_addr := dp_read_addr_reg
      impl_io.mem_addr := mem_addr_reg
      impl_io.mem_write_data := mem_write_data_reg
      impl_io.mem_write_en := mem_write_en_reg

      load_count_wire.bits := impl_io.load_count
      load_count_wire.valid := true.B

      when (mem_write_en_reg) {
        mem_write_en_reg := false.B
      }

      node.regmap(
        0x00 -> Seq(RegField.r(2, status, RegFieldDesc("status", "Status of the accelerator (input_ready, output_valid)."))),
        0x04 -> Seq(RegField.w(params.width, ax, RegFieldDesc("ax", "Input data. Writing to this register triggers computation."))),
        0x08 -> Seq(RegField.r((2 * params.width), res, RegFieldDesc("res", "Result of the computation."))),
        // Assuming 32-bit width, res is 64-bit and takes up 0x08 and 0x0C
        0x10 -> Seq(RegField.r(log2Ceil(33), load_count_wire, RegFieldDesc("load_count", "Number of vector sets loaded (0-33)."))),
        0x14 -> Seq(RegField.w(log2Ceil(192), mem_addr_reg, RegFieldDesc("mem_addr", "Address for internal memory write operations (0-191)."))),
        0x18 -> Seq(RegField.w(params.width, mem_write_data_reg, RegFieldDesc("mem_write_data", "Data to write to the internal memory at mem_addr."))),
        0x1C -> Seq(RegField.w(1, mem_write_en_reg, RegFieldDesc("mem_write_en", "Pulse high to enable memory write operation."))),
        0x20 -> Seq(RegField.w(6, dp_read_addr_reg, RegFieldDesc("dp_read_addr", "Address (0-33) of DP result to read via 'res' port.")))
      )
    }
  }
}

class HLSGCDAccel(params: GCDParams, beatBytes: Int)(implicit p: Parameters) extends ClockSinkDomain(ClockSinkParameters())(p) {
  val device = new SimpleDevice("hlsgcdaccel", Seq("ucbbar,hlsgcdaccel"))
  val node = TLRegisterNode(Seq(AddressSet(params.address, 4096-1)), device, "reg/control", beatBytes=beatBytes)

  override lazy val module = new HLSGCDAccelImpl
  class HLSGCDAccelImpl extends Impl with HasGCDTopIO {
    val io = IO(new GCDTopIO)
    withClockAndReset(clock, reset) {
      val ax = Wire(new DecoupledIO(UInt(params.width.W)))
      val res = Wire(new DecoupledIO(UInt((2 * params.width).W)))

      val impl = Module(new HLSGCDAccelBlackBox(params.width))

      impl.io.ap_clk := clock
      impl.io.ap_rst := reset

      val s_idle :: s_busy :: Nil = Enum(2)
      val state = RegInit(s_idle)

      when (state === s_idle && ax.valid) {
        state := s_busy
      } .elsewhen (state === s_busy && impl.io.ap_done) {
        state := s_idle
      }

      impl.io.ap_start := (state === s_idle && ax.valid)
      res.valid := (state === s_busy && impl.io.ap_done)

      val status = Cat(impl.io.ap_idle, res.valid)

      impl.io.ax := ax.bits
      res.bits  := impl.io.ap_return

      ax.ready := (state === s_idle)

      io.gcd_busy := !impl.io.ap_idle

      node.regmap(
        0x00 -> Seq(RegField.r(2, status)),
        0x04 -> Seq(RegField.w(params.width, ax)),
        0x08 -> Seq(RegField.r((2 * params.width), res))
      )
    }
  }
}

// DOC include start: GCD lazy trait
trait CanHavePeripheryGCD { this: BaseSubsystem =>
  private val portName = "gcd"
  private val pbus = locateTLBusWrapper(PBUS)

  private val periphery_port_info = p(GCDKey).map { params =>
    val gcd_clock_source = Option.when(params.externallyClocked) {
      InModuleBody { IO(Input(Clock())).suggestName("gcd_clock_in") }
    }
    val gcdClockNode = if (params.externallyClocked) {
      val gcdSourceClockNode = ClockSourceNode(Seq(ClockSourceParameters()))
      InModuleBody {
        gcdSourceClockNode.out(0)._1.clock := gcd_clock_source.get
        gcdSourceClockNode.out(0)._1.reset := ResetCatchAndSync(gcd_clock_source.get, pbus.module.reset.asBool)
      }
      gcdSourceClockNode
    } else {
      pbus.fixedClockNode
    }
    val gcdCrossing = if (params.externallyClocked) {
      AsynchronousCrossing()
    } else {
      SynchronousCrossing()
    }

    val gcd = if (params.useAXI4) {
      val gcd = LazyModule(new GCDAXI4(params, pbus.beatBytes)(p))
      gcd.clockNode := gcdClockNode
      pbus.coupleTo(portName) {
        AXI4InwardClockCrossingHelper("gcd_crossing", gcd, gcd.node)(gcdCrossing) :=
        AXI4Buffer () :=
        TLToAXI4 () :=
        TLFragmenter(pbus.beatBytes, pbus.blockBytes, holdFirstDeny = true) := _
      }
      gcd
    } else if (params.useHLS) {
      val gcd = LazyModule(new HLSGCDAccel(params, pbus.beatBytes)(p))
      gcd.clockNode := gcdClockNode
      pbus.coupleTo(portName) {
        TLInwardClockCrossingHelper("gcd_crossing", gcd, gcd.node)(gcdCrossing) :=
        TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
      }
      gcd
    } else {
      val gcd = LazyModule(new GCDTL(params, pbus.beatBytes)(p))
      gcd.clockNode := gcdClockNode
      pbus.coupleTo(portName) {
        TLInwardClockCrossingHelper("gcd_crossing", gcd, gcd.node)(gcdCrossing) :=
        TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
      }
      gcd
    }

    val busy_signal = InModuleBody {
      val top_level_busy_io = IO(Output(Bool())).suggestName("gcd_busy")
      top_level_busy_io := gcd.module.io.gcd_busy
      top_level_busy_io
    }
    (busy_signal, gcd_clock_source)
  }

  lazy val gcd_busy = periphery_port_info.map(_._1)
  lazy val gcd_clock = periphery_port_info.flatMap(_._2)
}
// DOC include end: GCD lazy trait

// DOC include start: GCD config fragment
class WithGCD(useAXI4: Boolean = true, useBlackBox: Boolean = true, useHLS: Boolean = false, externallyClocked: Boolean = false) extends Config((site, here, up) => {
  case GCDKey => {
    assert(!useHLS || (useHLS && !useAXI4 && !useBlackBox))
    Some(GCDParams(useAXI4 = false, useBlackBox = useBlackBox, useHLS = useHLS, externallyClocked = externallyClocked))
  }
})
// DOC include end: GCD config fragment
