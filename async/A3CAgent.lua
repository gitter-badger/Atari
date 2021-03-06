local classic = require 'classic'
local optim = require 'optim'
local AsyncAgent = require 'async/AsyncAgent'
require 'modules/sharedRmsProp'

local A3CAgent,super = classic.class('A3CAgent', 'AsyncAgent')


function A3CAgent:_init(opt, policyNet, targetNet, theta, targetTheta, atomic, sharedG)
  super._init(self, opt, policyNet, targetNet, theta, targetTheta, atomic, sharedG)

  log.info('creating A3CAgent')

  self.policyNet_ = policyNet:clone()

  self.theta_, self.dTheta_ = self.policyNet_:getParameters()
  self.dTheta_:zero()

  self.policyTarget = self.Tensor(self.m)
  self.vTarget = self.Tensor(1)
  self.targets = { self.vTarget, self.policyTarget }

  self.rewards = torch.Tensor(self.batchSize)
  self.actions = torch.ByteTensor(self.batchSize)
  self.states = torch.Tensor(0)
  self.beta = 0.01

  if self.ale then self.env:training() end

  classic.strict(self)
end


function A3CAgent:learn(steps, from)
  self.step = from or 0

  self.stateBuffer:clear()

  log.info('A3CAgent starting | steps=%d', steps)
  local reward, terminal, state = self:start()

  self.states:resize(self.batchSize, unpack(state:size():totable()))

  self.tic = torch.tic()
  repeat
    self.theta_:copy(self.theta)
    self.batchIdx = 0
    repeat
      self.batchIdx = self.batchIdx + 1
      self.states[self.batchIdx]:copy(state)

      local V, probability = unpack(self.policyNet_:forward(state))
      local action = torch.multinomial(probability, 1):squeeze()

      self.actions[self.batchIdx] = action

      reward, terminal, state = self:takeAction(action)
      self.rewards[self.batchIdx] = reward

      self:progress(steps)
    until terminal or self.batchIdx == self.batchSize

    self:accumulateGradients(terminal, state)

    if terminal then 
      reward, terminal, state = self:start()
    end

    self:applyGradients(self.policyNet_, self.dTheta_, self.theta)
  until self.step >= steps

  log.info('A3CAgent ended learning steps=%d', steps)
end


function A3CAgent:accumulateGradients(terminal, state)
  local R = 0
  if not terminal then
    R = self.policyNet_:forward(state)[1]
  end

  for i=self.batchIdx,1,-1 do
    R = self.rewards[i] + self.gamma * R
    
    local action = self.actions[i]
    local V, probability = unpack(self.policyNet_:forward(self.states[i]))
    probability:add(1e-100) -- could contain 0 -> log(0)= -inf -> theta = nans

    self.vTarget[1] = -0.5 * (R - V)

    self.policyTarget:zero()
    local logProbability = torch.log(probability)
    self.policyTarget[action] = -(R - V) / probability[action]  - self.beta * logProbability:sum()

    self.policyNet_:backward(self.states[i], self.targets)
  end
end


function A3CAgent:progress(steps)
  self.atomic:inc()
  self.step = self.step + 1
  if self.step % self.progFreq == 0 then
    local progressPercent = 100 * self.step / steps
    local speed = self.progFreq / torch.toc(self.tic)
    self.tic = torch.tic()
    log.info('A3CAgent | step=%d | %.02f%% | speed=%d/sec | η=%.8f',
      self.step, progressPercent, speed, self.optimParams.learningRate)
  end
end

return A3CAgent

