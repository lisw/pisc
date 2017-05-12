local ffi  = require("ffi");
local json = require("json");
local uart = require("uart");
local time = require("time");
local timer = require("timer");
local copas = require("copas");
local packet= require("packet");
local sformat,tconcat = string.format, table.concat;

local logger = require("log4lua.logger");
logger.loadConfig("log4lua.conf");
log = logger.getLogger("pisc");

QUERY_CMD  = 0x0C;
QUERY_DATA = "\x00";

local config_file= 'pisc.conf';   -- config file name
local conf = {   -- configuration parameters, deviceType PISC:1, DCP:2, LCU:3, DRM:4
    dev_id  = 0x01;      -- deviceId, PISC: 0x01,0x11; DACU: 0x21,0x31; PAU: 0x41,0x51,0x61,0x71; LCU: 0x03,0x13,0x23,0x33,0x43,0x53
    query_period = 0.5;  -- query command packet period in seconds
    active  = true;      -- master PISC

    -- net_id:networkId, main net: 0xfe; subnet of LCU: 1..6; subnet of PISC: 0xf1..0xf2
    uarts = {
        {devname="/dev/ttyO1", baudrate=9600, databits=8, stopbits=1, parity=0, utype=1, net_id=0xf1,
            query_ids={0x21,0x31,0x03,0x13,0x23,0x33,0x43,0x53}
        },
        {devname="/dev/ttyO2", baudrate=9600, databits=8, stopbits=1, parity=0, utype=1, net_id=0xfe,
            query_ids={0x41,0x51,0x61,0x71}
        },
    };

    heartbeat = 1;
};

tasks = {};
state = {dacus={}, paus={}, lcus={}};

function fileread(name)
    local file = io.open(name, "r");
    if file then
        local s = file:read("*a");
        file:close();
        return s;
    end;
end;

function filewrite(name, ...)
    local file = io.open(name, "w");
    if file then
        file:write(...);
        file:close();
    end;
end;

function configload()
    local line = fileread(config_file);
    if not line then return; end;
    local c = json.decode(line);
    if type(c) ~= "table" then return; end;
    for k,v in pairs(conf) do
        c[k] = c[k] or v;
    end;
    conf = c;
end;

function configsave()
    filewrite(config_file, json.encode(conf), "\n");
end;

function sleep(...)
    (coroutine.running() and copas.sleep or time.sleep)(...);
end;

function loadplugin(dir)
    dir = dir or "plugin";
    dir = (os.type=="Windows" and "dir " or "ls ") .. dir;
    local f = io.popen(dir);
    local l = f:read("*a");
    f:close();
    for f in l:gmatch("(%S+)%.lua") do
        log:info("Load plugin: " .. f);
        pcall(require, "plugin." .. f);
    end;
end;

function dout_set(ch, value)
    ch = tonumber(ch) or 0;
    value = (value == 1 or value == true) and 1 or 0;
    local file = sformat("/sys/class/gpio/gpio%d/value", ch+168);
    file = io.open(file, "w");
    if not file then return end;
    file:write(value);
    file:close();
end;

function din_get(ch)
    ch = tonumber(ch) or 0;
    local file = sformat("/sys/class/gpio/gpio%d/value", ch+113);
    file = io.open(file, "r");
    if not file then return end;
    local value = tonumber(file:read());
    file:close();
    return value;
end;

local din = {1,1,1,1};
function din_test()
    for i=1,4 do
        local value = din_get(i-1);
        if value ~= din[i] then
            local msg = sformat("din %d changed, value = %s", i, value);
            print(msg);
            log:debug(msg);
            din[i] = value;
        end;
    end;
end;

function uart_open(u)
  local parity = u.parity;
  local handle = uart.open(u.devname,u.baudrate,u.databits,parity,u.stopbits);
  parity = parity==0 and 'N' or (parity==1 and 'O' or 'E');
  if not handle then
    log:info(("Uart open error: %s, %d %d%s%d"):format(u.devname, u.baudrate, u.databits, parity, u.stopbits));
    return;
  end;
  log:debug(("Uart open: %s, %d %d%s%d"):format(u.devname, u.baudrate, u.databits, parity, u.stopbits));
  handle:set485(u.utype);
  handle.pool = {};
  for k,v in pairs(u) do
    handle[k] = v;
  end;
  return handle;
end;

devTest = {};
function uart_test(port, baud)
  if port then
    port = tonumber(port) or 0;
    devTest.port = port;
    devTest.reinit = true;

    if port >= 0 then
      local u = conf.uarts[port+1];
      if type(u) ~= "table" then
        log:info(sformat("No uart port: %d found", port));
        devTest.port = -1;
        return;
      end;

      devTest.devname  = u.devname;
      devTest.baudrate = baud or tonumber(u.baudrate) or 115200;
      devTest.databits = tonumber(u.databits) or 8;
      devTest.stopbits = tonumber(u.stopbits) or 1;
      devTest.parity = u.parity;
      devTest.utype = tonumber(u.utype);
      local msg = sformat("uart test %d %s %d %d%s%d",
        devTest.port,devTest.devname,devTest.baudrate,devTest.databits,devTest.parity,devTest.stopbits);
      log:debug(msg);
    end;
    return;
  end;

  if devTest.reinit then
    devTest.reinit = nil;
    if devTest.handle then
      devTest.handle:close();
      devTest.handle = nil;
      log:debug(sformat("uart test close %s", devTest.devname));
    end;
    if devTest.port >= 0 then
      devTest.handle = uart_open(devTest);
    end;
  end;

  if not devTest.handle then
    return;
  end;

  local line = devTest.handle:get();
  if not line then
    local parity = devTest.parity;
    parity = parity==0 and 'N' or (parity==1 and 'O' or 'E');
    line = os.date("%Y-%m-%d %H:%M:%S");
    line = line .. sformat(", %d %s %d %d%s%d",
      devTest.port, devTest.devname, devTest.baudrate, devTest.databits, parity, devTest.stopbits);
  end;
  devTest.handle:put(line .. "\n\r");
end;

function uart_proc(udev)
  local pool = udev.pool;
  local query_time = -1;
  local query_index = 0;
  while true do
    local pkt = table.remove(pool, 1);
    local now = time.time();
    if not pkt and now-query_time > conf.query_period and udev.query_ids then
      query_index = query_index >= #udev.query_ids and 1 or query_index+1;
      query_time = now;
      local query_id = udev.query_ids[query_index];
      if query_id then
        pkt = packet.build(0, query_id, 0, conf.dev_id, QUERY_CMD, QUERY_DATA);
      end;
    end;
    if pkt then
      log:debug("Send packet, " .. packet.hexstring(pkt));
      packet.send(udev, pkt);
    end;

    local pkt, err = packet.recv(udev, true);
    if err then
      log:debug(err);
    elseif pkt then
      log:debug(sformat("dev %s get packet %s", udev.devname, packet.hexstring(pkt)));
      local destNet,destDev,srcNet,srcDev,cmd,data = packet.parse(pkt);
      if not destNet then
        log:warn("Error packet, " .. destDev);
      else
        log:debug(sformat("Recv packet, %02X:%02X %02X:%02X %02X, %s", destNet,destDev,srcNet,srcDev,cmd,packet.hexstring(data)));
      end;

      if destNet ~= 0 then -- this packet is not for us
        if destNet == udev.net_id then -- need route packet to another subnet
          log:debug(sformat("Route packet to subnet %02X", destNet));
          local u = udev==udev0 and udev1 or udev0; -- udev for another subnet
          table.insert(u.pool, pkt);
        end;
      elseif cmd == QUERY_CMD and #data==1 and data:byte()==0x00 and destDev==conf.dev_id then -- query packet
        data = "\x80";
        for i=1,4 do
          data = data .. string.char(state.paus[i] or 0);
        end;
        pkt = packet.build(srcNet, srcDev, destNet, destDev, cmd, data);
        table.insert(pool, pkt); -- insert response packet to send pool
      elseif cmd == QUERY_CMD and #data >= 2 and data:byte() == 0x80 then -- reponse of query packet
        local devType = srcDev % 16;
        local devAddr = (srcDev - devType) / 16;
        if devType == 1 and devAddr >= 2 and devAddr <= 3 then -- DACU
          log:debug(sformat("DACU response: %s", packet.hexstring(data)));
          state.dacus[devAddr-1] = data:byte(2);
        elseif devType == 1 and devAddr >= 4 and devAddr <= 7 then -- PAU
          log:debug(sformat("PAU response: %s", packet.hexstring(data)));
          state.paus[devAddr-3] = data:byte(2);
        elseif devType == 3 then -- LCU
          log:debug(sformat("LCU response: %s", packet.hexstring(data)));
          state.lcus[devAddr+1] = data:byte(2);
        else
          log:debug(sformat("Unknown response: %02X %s", srcDev, packet.hexstring(data)));
        end;
      end;
    end;
  end;
end;

function initialize()
  log:info("Initializing...");
  local file,ostype = io.popen("busybox uname", "r"), "Windows";
  if file then
    ostype = file:read();
    file:close();
  end;
  os.type = ostype;
  log:info("System type: " .. ostype);
  configload();
  copas.init();
  loadplugin();
  udev0 = uart_open(conf.uarts[1]);
  udev1 = uart_open(conf.uarts[2]);
  if udev0 then copas.addthread(uart_proc, udev0) end;
  if udev1 then copas.addthread(uart_proc, udev1) end;
  collectgarbage("collect");

  -- user tasks from plugin
  for oid, task in pairs(tasks) do
    if type(task) == "table" and type(task.proc) == "function" then
      copas.addthread(task.proc, task);
    end;
  end;

  return true;
end;

function dump(o,f,p)
  p = p or "";
  f = f or io.output();

  if type(o) == "number" then
    f:write(o);
  elseif type(o) ~= "table" then
    f:write(("%q"):format(tostring(o)));
  else
    f:write("{\n");
    for k,v in pairs(o) do
      f:write(p, "  [", type(k)=="number" and k or ("%q"):format(k), "] = ");
      dump(v, f, p.."  ");
    end;
    f:write(p, "}");
  end;
  f:write(";\n");
end;

function save(obj,objName,fileName)
  f = io.open(fileName, "w");
  f:write(objName, " = ");
  dump(obj, f);
  f:close();
end;

reinit = true;
quit = false;

function main()
    local tmr_test = timer.new(2, -1, uart_test);

    while not(quit) do
        sleep(0.1);
        if reinit then
            if not initialize() then break end;
            reinit = false;
        end;

        timer.step();
        copas.step();
        --din_test();
    end;

    log:info("Exiting...");
end;
--[[
function hook(event)
  local funcInfo = debug.getinfo( 2, 'nS' );
	local name  = funcInfo.name or 'anonymous';
	local source= funcInfo.short_src or 'C_FUNC';
	local line  = funcInfo.linedefined or 0;
	local title = string.format("%d \t %s: %s: %d", os.clock(), source, name, line);
	log:debug(title);
end;
debug.sethook(hook, "cr");
]]

if not arg or #arg == 0 then
    local ok, msg = pcall(main);
    if not ok then
        log:error(msg);
    end;
end;
