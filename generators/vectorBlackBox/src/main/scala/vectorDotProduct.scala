package chipyard.example
package myproject

import chisel3._
import chisel3.experimental.{ExtModule, ChiselAnnotation}
import freechips.rocketchip.config.Parameters
import freechips.rocketchip.subsystem.BaseSubsystem
import freechips.rocketchip.tilelink.{TLClientNode, TLBundle}
import freechips.rocketchip.diplomacy.LazyModule

/package chipyard.example
package chipyard

import sys.process._

import chisel3._
import chisel3.util._
import chisel3.experimental.{IntParam, BaseModule}
import freechips.rocketchip.amba.axi4._
import freechips.rocketchip.prci._
import freechips.rocketchip.subsystem.{BaseSubsystem, PBUS}
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.regmapper.{HasRegMap, RegField}
import freechips.rocketchip.tilelink._
import freechips.rocketchip.util._
case class VectorMultiparams(
  address: BigInt = 0x4000,
  width: Int = 32,
  useAXI4: Boolean = false,
  useBlackBox: Boolean = true,
  useHLS: Boolean = false,
  externallyClocked: Boolean = false
) {
  require(!(useAXI4 && useHLS))
}

// BlackBox Definition with Resource Annotation
class VectorMultiBlackBox extends Bundle{
  val ax = Input(Vec(32, UInt(32.W)))
  val ay = Input(Vec(32, UInt(32.W)))
  val az = Input(Vec(32, UInt(32.W)))
  val bx = Input(Vec(32, UInt(32.W)))
  val by = Input(Vec(32, UInt(32.W)))
  val bz = Input(Vec(32, UInt(32.W)))
  val scalar_out = Output(Vec(32, UInt(64.W)))

}

// Wrapper for Integration in Chipyard
class VectorMultiWrapper(implicit p: Parameters) extends LazyModule {
  val clientNode = TLClientNode(Seq())

  lazy val module = new LazyModuleImp(this) {
    val io = IO(new Bundle {
      val ax = Input(Vec(32, UInt(32.W)))
      val ay = Input(Vec(32, UInt(32.W)))
      val az = Input(Vec(32, UInt(32.W)))
      val bx = Input(Vec(32, UInt(32.W)))
      val by = Input(Vec(32, UInt(32.W)))
      val bz = Input(Vec(32, UInt(32.W)))
      val scalar_out = Output(Vec(32, UInt(64.W)))
    })
  }
}
// DOC include start: Vector blackbox
class vectorBlackBox(val w: Int) extends BlackBox(Map("WIDTH" -> IntParam(w))) with HasBlackBoxResource {
  val io = IO(new VectorMultiBlackBox())
  addResource("/vsrc/vectorDotProduct.v")
}
