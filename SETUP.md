# SSH

## SSH into Pi
SSH into the Pi with:
```bash
ssh user@ip

# or

ssh user@pi
# If you've set that in the etc/hosts
```

## SSH into Rig
Then from the Pi, SSH into the rig with:
```bash
ssh 10.42.0.2

# or

ssh rig
# If you've set up etc/hosts
```

To log in while on the same network as the Pi, run in CMD:
```bash
ssh user@orchestrator.local
```

Being on a VPN will mess this up.

To Shut down you run: 
```bash
sudo shutdown now
```

Otherwise, to exit SSH without shutdown just run:
```bash
exit
```

<br><br>
# Shutdown

## Shutdown the Pi
```bash
sudo halt
```

## Shutdown the Rig
```bash
# Safer shutdown:
sudo systemctl suspend

sudo poweroff
```

<br><br>
# Running Server

To start the `orchestrator` server, run:
```bash
pm2 start server.js --name orchestrator
```

You'll see a table with the metrics for the server.

Then you check to see if it's working with:
```bash
pm2 logs orchestrator
```

You can exit the logs with `ctrl` + `c` while keeping the server running in the background.

Making it start on boot is done with:
```bash
pm2 save
```

Then finish by running this to make it hook into the Linux boot scripts:
```bash
pm2 startup
```

## Check Server Status
```bash
pm2 status

pm2 logs
```

## Restart & Stop
```bash
pm2 stop orchestrator
pm2 restart orchestrator
```

## Remove Script From Run on Startup
```bash
pm2 unstartup systemd
```

<br><br>
# Running Rig
---
Go to `Miner` directory:
```
cd Miner
```

In the rig terminal, start a "Screen" session to keep it running even after you `exit`:
```bash
screen -S mining_session
```

Start the miner:
```bash
sudo ./miner.sh
```

Detach:
1. Press `CTRL` + `A`
2. Press `D`

Safely Disconnect:
```bash
exit
```

When you want to reconnect to the miner run:
```bash
screen -r mining_session
```

To list all screen sessions:
```bash
screen -ls
```

<br><br>
# Network Connections

## Get WIFI on the Pi
To view the interfaces on the Pi run:
```
ifconfig
```

Then, to view the networks that an interface can see, in this case `wlan1`, run:
```bash
sudo nmcli dev wifi list ifname wlan1
```

Then, to connect to a network an an interface, in this case `wlan1` run:
```bash
sudo nmcli dev wifi connect "network-name" ifname wlan1
```

To verify, run:
```bash
ifconfig wlan1
```

And make sure you're online with:
```bash
ping google.com
```

To disable the old wifi interface so the Pi doesn't get confused, run:
```bash
sudo ip link set wlan0 down
```

To reactivate it, run:
```bash
sudo ip link set wlan0 up
```

Setup a private network to SSH in from anywhere with tailscale:
```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

Then:
```bash
sudo tailscale up
```

Go to the site and authenticate. For `Orchestrator` I authed with Github.

Download on PC and check in Tailscale the IP for the Pi. Then run the SSH command with that IP:
```bash
ssh user@yourIP
```

## Connect Ethernet cable to Rig to share network
---
First create a shared network interface on `eth0` the standard ethernet port in the Pi.
```bash
sudo nmcli connection add type ethernet ifname eth0 ipv4.method shared con-name "SharedEthernet"
```

Then, verify that it created with:
```bash
ip addr
```

Now, turn on rig so they can communicate and on the Pi run this to show the connections:
```bash
nmcli connection show
```

Then, use the `SharedEthernet` connection that we created with:
```bash
sudo nmcli connection up "SharedEthernet"
```

The Rig now has internet connection. Make it so that the Pi autoconnects (optional) with:
```bash
sudo nmcli connection modify "SharedEthernet" connection.autoconnect yes
```

On the rig, make it always appear with the same IP so I can always SSH in from the Pi even offline. First check connections with:
```bash
nmcli connection show
```

Then, whatever the Pi's connection is, change it with this command, in this case `Wired connection 1`:
```bash
sudo nmcli connection modify "Wired connection 1" ipv4.addresses 10.42.0.2/24 ipv4.gateway 10.42.0.1 ipv4.method manual
```

Then apply it:
```bash
sudo nmcli connection up "Wired connection 1"
```

<br><br>
# Wake Rig from Pi
---
Install `ethtool` on rig:
```bash
sudo apt install ethtool -y
```

Then run `ip addr` to get the name of the interface on the rig and run this:
```bash
sudo ethtool <YOUR_INTERFACE_NAME> | grep Wake-on
```

Then `sudo poweroff` and on the Pi install:
```bash
sudo apt install etherwake -y
```

Then run the command to send the "magic packet" that will wake the rig. Put in the ethernet interface and the rigs MAC addy:
```bash
sudo etherwake -i eth0 YOUR:MAC:ADDY:HERE
```

<br><br>
# Control Fans:

Controlling Nvidia GPU fans on a headless linux machine. War.

First, download `xorg`:
```bash
sudo apt install -y xserver-xorg xinit nvidia-settings
```

Then we need to make sure its configured correctly:
```bash
sudo nano /etc/X11/xorg.conf
```

Go to `Devices` and set it to this or similar the `AllowEmptyInitialConfiguration` option is what's important here. It must be set to `true`:
```bash
Section "Device"
    Identifier     "Device0"
    Driver         "nvidia"
    VendorName     "NVIDIA Corporation"
    Option         "CoolBits" "4"
    Option         "AllowEmptyInitialConfiguration" "true"
EndSection
```

Also, in the screen section make sure `Device:` matches the `Identifier:` in Device:
```bash
Section "Screen"
    Identifier     "Screen0"
    Device         "Device0"
    Monitor        "Monitor0"
    DefaultDepth    24
    SubSection     "Display"
        Depth       24
    EndSubSection
EndSection
```

Now restart `xorg` by rebooting:
```bash
sudo reboot
```

Start the X display that the GPU needs to communicate with and then open a new Terminal window:
```bash
sudo X :0
```

These commands should now work to adjust the fans:
```bash
export DISPLAY=:0
DISPLAY=:0 nvidia-settings -a "[gpu:0]/GPUFanControlState=1"
DISPLAY=:0 nvidia-settings -a "[fan:0]/GPUTargetFanSpeed=70"
```

## Fan control
`nvidia-settings -a "[gpu:0]/GPUFanControlState=1"` - enables manual fan control.
`nvidia-settings -a "[gpu:0]/GPUFanControlState=0"` - auto fan control

## Set fan speed (manual mode only)
`nvidia-settings -a "[fan:0]/GPUTargetFanSpeed=70

## Check current mode
`nvidia-settings -q "[gpu:0]/GPUFanControlState"`

## Turn Fans On
---
1. Start X server (headless display):
```bash
sudo X :0
```

2. Set control to manual:
```bash
DISPLAY=:0 nvidia-settings -a "[gpu:0]/GPUFanControlState=1"
```

3. Set fan speed:
```bash
DISPLAY=:0 nvidia-settings -a "[fan:0]/GPUTargetFanSpeed=70"
```

## Turn Fans Off
---
1. Start X server (headless display):
```bash
sudo X :0
```

2. Set control to manual:
```bash
DISPLAY=:0 nvidia-settings -a "[gpu:0]/GPUFanControlState=1"
```

3. Set control to automatic:
```bash
DISPLAY=:0 nvidia-settings -a "[gpu:0]/GPUFanControlState=0"
```

<br><br>
# Example Keyhunt output

```
user@pop-os:~/Miner$ /home/user/Miner/VanitySearch/vanitysearch -t 0 -gpu -i targets.txt --keyspace 20000000000000000:+500000000
VanitySearch v1.17 Linux with BitCrack integration
[keyspace] start=20000000000000000
[keyspace]   end=20000000500000000
Output File:
Search: 13zb1hQbWVsc2S7ZTZnP2G4undNNpdh5so [Compressed]
Current task START time: Wed Jan 14 23:07:27 2026
GPU: GPU #0 NVIDIA GeForce RTX 3080 (68x128 cores) Grid(8192x256)
Divide by 0!
[EXIT] Range search completed 09 RUN || END 00:00:01] [0]
Current task END time: Wed Jan 14 23:07:41 202600:00] [0]
```

<br><br>
# Telegram Alert Bot

Create bot with `@botfather` then put your API key in the `.env` file.
<br><br>
# Working Makefile for KeyHunt with RTX 3080 (If you're having issues)

```bash
cat << 'EOF' > Makefile
# Hardcoded Makefile for RTX 3080 (Ampere)
CXX = g++-9
CC = gcc
LD = g++-9

# CUDA PATHS (For apt-installed CUDA)
CUDA = /usr
CXXCUDA = /usr/bin/g++-9
NVCC = $(CUDA)/bin/nvcc

# FLAGS
# Hardcoded for RTX 3080 (Compute 86)
NVCC_FLAGS = -gencode=arch=compute_86,code=\"sm_86,compute_86\" -Xptxas -v -m 64
CXXFLAGS = -DWITHGPU -mssse3 -Wno-write-strings -O2 -I. -I$(CUDA)/include
LDFLAGS = -lpthread -L$(CUDA)/lib64 -lcudart

# SOURCE FILES
DIR_OBJ = obj
DIR_GPU = GPU
DIR_HASH = hash

OBJ_CPP = $(DIR_OBJ)/Base58.o \
          $(DIR_OBJ)/IntGroup.o \
          $(DIR_OBJ)/main.o \
          $(DIR_OBJ)/Random.o \
          $(DIR_OBJ)/Timer.o \
          $(DIR_OBJ)/Int.o \
          $(DIR_OBJ)/IntMod.o \
          $(DIR_OBJ)/Point.o \
          $(DIR_OBJ)/SECP256K1.o \
          $(DIR_OBJ)/Vanity.o \
          $(DIR_OBJ)/Bech32.o \
          $(DIR_OBJ)/Wildcard.o

OBJ_CU = $(DIR_OBJ)/$(DIR_GPU)/GPUEngine.o
OBJ_GPU_CPP = $(DIR_OBJ)/$(DIR_GPU)/GPUGenerate.o

OBJ_HASH = $(DIR_OBJ)/$(DIR_HASH)/ripemd160.o \
           $(DIR_OBJ)/$(DIR_HASH)/sha256.o \
           $(DIR_OBJ)/$(DIR_HASH)/sha512.o \
           $(DIR_OBJ)/$(DIR_HASH)/ripemd160_sse.o \
           $(DIR_OBJ)/$(DIR_HASH)/sha256_sse.o

all: directories vanitysearch

directories:
	mkdir -p $(DIR_OBJ)
	mkdir -p $(DIR_OBJ)/$(DIR_GPU)
	mkdir -p $(DIR_OBJ)/$(DIR_HASH)

vanitysearch: $(OBJ_CPP) $(OBJ_CU) $(OBJ_GPU_CPP) $(OBJ_HASH)
	@echo "Linking vanitysearch..."
	$(LD) $^ $(LDFLAGS) -o vanitysearch

$(DIR_OBJ)/%.o: %.cpp
	$(CXX) $(CXXFLAGS) -o $@ -c $<

$(DIR_OBJ)/$(DIR_GPU)/%.o: $(DIR_GPU)/%.cpp
	$(CXX) $(CXXFLAGS) -o $@ -c $<

$(DIR_OBJ)/$(DIR_GPU)/%.o: $(DIR_GPU)/%.cu
	$(NVCC) $(NVCC_FLAGS) -ccbin $(CXXCUDA) -I$(CUDA)/include -O2 -o $@ -c $<

$(DIR_OBJ)/$(DIR_HASH)/%.o: $(DIR_HASH)/%.cpp
	$(CXX) $(CXXFLAGS) -o $@ -c $<

clean:
	rm -rf $(DIR_OBJ) vanitysearch
EOF
```
