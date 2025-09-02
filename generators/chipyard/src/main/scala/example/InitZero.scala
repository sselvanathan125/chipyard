
package chipyard.example

import chisel3._
import chisel3.util._
import freechips.rocketchip.subsystem._
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import freechips.rocketchip.diplomacy.{LazyModule, LazyModuleImp, IdRange}
import freechips.rocketchip.tilelink._
import testchipip.soc.{SubsystemInjector, SubsystemInjectorKey}
import freechips.rocketchip.regmapper.{HasRegMap, RegField, RegFieldDesc}

case class InitZeroConfig(base: BigInt, size: BigInt)
case object InitZeroKey extends Field[Option[InitZeroConfig]](None)

class InitZero(implicit p: Parameters) extends LazyModule {
  val node = TLClientNode(Seq(TLMasterPortParameters.v1(Seq(TLClientParameters(
    name = "init-zero", sourceId = IdRange(0, 1))))))

  lazy val module = new InitZeroModuleImp(this)
}

class InitZeroModuleImp(outer: InitZero) extends LazyModuleImp(outer) {
  val config = p(InitZeroKey).get

  val (mem, edge) = outer.node.out(0)
  val addrBits = edge.bundle.addressBits
  val blockBytes = p(CacheBlockBytes)

  require(config.size % blockBytes == 0)

  val s_init :: s_write :: s_resp :: s_done :: Nil = Enum(4)
  val state = RegInit(s_init)

  val addr = Reg(UInt(addrBits.W))
  val bytesLeft = Reg(UInt(log2Ceil(config.size+1).W))

  mem.a.valid := state === s_write
  mem.a.bits := edge.Put(
    fromSource = 0.U,
    toAddress = addr,
    lgSize = log2Ceil(blockBytes).U,
    data = 100.U)._2
  mem.d.ready := state === s_resp

  when (state === s_init) {
    addr := config.base.U
    bytesLeft := config.size.U
    state := s_write
  }

  when (edge.done(mem.a)) {
    addr := addr + blockBytes.U
    bytesLeft := bytesLeft - blockBytes.U
    state := s_resp
  }

  when (mem.d.fire) {
    state := Mux(bytesLeft === 0.U, s_done, s_write)
  }
}

case object InitZeroInjector extends SubsystemInjector((p, baseSubsystem) => {
  p(InitZeroKey) .map { k =>
    implicit val q: Parameters = p
    val fbus = baseSubsystem.locateTLBusWrapper(FBUS)
    val initZero = fbus { LazyModule(new InitZero()(p)) }
    fbus.coupleFrom("init-zero") { _ := initZero.node }
  }
})


// DOC include start: WithInitZero
class WithInitZero(base: BigInt, size: BigInt) extends Config((site, here, up) => {
  case InitZeroKey => Some(InitZeroConfig(base, size))
  case SubsystemInjectorKey => up(SubsystemInjectorKey) + InitZeroInjector
})
// DOC include end: WithInitZero

