import { ethers } from 'hardhat'

async function main() {
  const validatorRegistry = process.env.PERMISSIONLESS_NODE_REGISTRY ?? ''
  const validatorRegistryFactory = await ethers.getContractFactory('PermissionlessNodeRegistry')
  const validatorRegistryInstance = await validatorRegistryFactory.attach(validatorRegistry)

  //   const porAddressList = await validatorRegistryInstance.addValidatorKeys(
  // ['0xa5dfd1c85461531c3bc9dc3fe21becd6f90f39bc550cfef143a3d3b74b6f548961138576af46ddc30c7fcbd0336850be'],
  // ['0x90ad43c8aff4d8ef1579cae8c43b9832e417b8aff0d037775f0fcf803af48cbcb741d1a461aaaeec52cdb2a56be0746903d7240ff03d2c7947a5fe90e33de80641f0bf4b1f6a1a0b9a5b151e817506c0ae4d7a28702d053bb3533defbde6721f'],
  // ['0xeed8d5ea163c423019d652b08abdd27caa55c9b69f043851e5868092b9100532'])

  const porAddressList = await validatorRegistryInstance.addValidatorKeys(
    [
      '0x8d5465707bf0a1cda82e6c275044bd4992cae8b971f284ae934396f98d8aaa500cf06c808891fb66ce55478b52cb5aca',
      '0x97de06821f635d9d234e311090bbad8e00512c85c6b57cae188ccfd633a67970849c2f461282639c18a0675a704244a3',
      '0xaff4a319f9ea46181a60b57bb601fcfa428a2aecdfeade93f2d063d17432dd39de84e51c1525ee93176e590ef2c22944',
    ],
    [
      '0x974d7a68b37e346540e4030db6b286060d4b4565eda40bd05a0afa94e6e656e23fb4d0d67e41791dc5fe9b7dbeee5a27050f0c9a9e295fdb59323935ffd5d8c0624f76c937e17b0b0c7ce40a9c6414fef7de1dbfb1884d475e9a4ab2c2a6d726',
      '0x858618f6575e6b660e7eab3bc520ad2899efdce972772c5ef9e5e4930bb54ce0d330ad5a7bd08392a15fbe60716b436c08e6907b406844494c9b2787758cf677049f31377dde95eebf92389b083fd16be79b1e4c7516ae0d921e79efa949096d',
      '0xad0d57a75819ff76aa069cafd66232c467a655daa59f37e618e26301cd371489a122a2f22ab15ed0a291d733cc4af43419e8ee31f86cf83274490c2f3465d0a241e8ec70334b0832e8778ac3db9e733281122245f202fb2e614f89c2926675de',
    ],
    { value: ethers.utils.parseEther('12') }
  )

  console.log('added keys')
}
main()