const vcDORA = artifacts.require('vcDORA')

const TestToken = artifacts.require('TestToken')

const WEEK = 7 * 86400

const toEther = (bn) => Math.round(Number(bn.toString()) / 1e10) / 1e8
const toWei = (n) => (BigInt(n * 1e8) * BigInt(1e10)).toString()

contract('vcDORA', (accounts) => {
  const founder = accounts[0]
  const u1 = accounts[1]
  const u2 = accounts[2]

  let token = null

  it('initialization', async () => {
    token = await TestToken.new(founder)
    let balance = await token.balanceOf.call(founder)

    await token.transfer(u1, toWei(1000))
    balance = await token.balanceOf.call(u1)
    assert.equal(balance.valueOf(), 1000e18, 'wrong u1 balance')

    await token.transfer(u2, toWei(1000))
    balance = await token.balanceOf.call(u2)
    assert.equal(balance.valueOf(), 1000e18, 'wrong u2 balance')
  })

  it('should be initialized', async () => {
    const instance = await vcDORA.deployed()
    await instance.init(token.address, 'vcDORA', 'VCD')

    const admin = await instance.admin.call()
    assert.equal(admin, founder, 'init error')
  })

  it('can locked token', async () => {
    const instance = await vcDORA.deployed()

    const now = Math.round(Date.now() / 1000)
    const epoch = [Math.floor(now / WEEK) * WEEK]
    for (let i = 0; i < 9; i++) {
      epoch.push(epoch[i] + WEEK)
    }

    await token.approve(instance.address, toWei(1e5), { from: u1 })
    await instance.createLock(toWei(208), now + 208 * WEEK, { from: u1 })
    let supply = await instance.totalSupplyAtFuture(epoch[1])
    assert.equal(toEther(supply), 207, 'supply error')

    await token.approve(instance.address, toWei(1e5), { from: u2 })
    await instance.createLock(toWei(208), now + 2 * WEEK, { from: u2 })
    supply = await instance.totalSupplyAtFuture(epoch[1])
    assert.equal(toEther(supply), 208, 'supply error')

    supply = await instance.totalSupplyAtFuture(epoch[2])
    assert.equal(toEther(supply), 206, 'supply error')

    supply = await instance.totalSupplyAtFuture(epoch[3])
    assert.equal(toEther(supply), 205, 'supply error')

    const admin = await instance.admin.call()
    assert.equal(admin, founder, 'init error')
  })
})
