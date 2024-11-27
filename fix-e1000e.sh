#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

INTERFACE="enp0s31f6"
MAX_ATTEMPTS=3
SLEEP_BETWEEN_ATTEMPTS=2

# Function to disable power management
disable_power_management() {
    echo "Disabling power management features..."
    
    # Disable Energy Efficient Ethernet
    ethtool --set-priv-flags $INTERFACE eee off 2>/dev/null
    
    # Disable Wake-on-LAN
    ethtool -s $INTERFACE wol d 2>/dev/null
    
    # Disable power management
    ethtool -s $INTERFACE advertise 0x01E1 2>/dev/null
    
    # Disable PCIe ASPM
    if [ -f "/sys/module/e1000e/parameters/SmartPowerDownEnable" ]; then
        echo "0" > /sys/module/e1000e/parameters/SmartPowerDownEnable
    fi
}

# Function for complete interface reset
full_reset() {
    for module in e1000e mei_me mei; do
        if lsmod | grep -q "^$module"; then
            echo "Unloading $module..."
            modprobe -r $module
        fi
    done
    
    sleep 2
    
    # Reset PCI device
    if [ -f "/sys/bus/pci/devices/*/driver/unbind" ]; then
        PCI_ADDR=$(lspci | grep Ethernet | cut -d' ' -f1)
        if [ ! -z "$PCI_ADDR" ]; then
            echo "0000:${PCI_ADDR}" > /sys/bus/pci/devices/*/driver/unbind 2>/dev/null
            sleep 1
            echo "0000:${PCI_ADDR}" > /sys/bus/pci/devices/*/driver/bind 2>/dev/null
        fi
    fi
    
    # Reload modules in correct order
    modprobe mei
    modprobe mei_me
    modprobe e1000e
    
    sleep 2
}

# Function to verify link status
check_link_status() {
    # Check physical link status using ethtool
    if ethtool $INTERFACE | grep -q "Link detected: yes"; then
        return 0
    fi
    return 1
}

# Main recovery function
recover_network() {
    echo "Starting network recovery procedure..."
    
    # Stop NetworkManager
    systemctl stop NetworkManager
    
    # Disable power management features
    disable_power_management
    
    # Perform full reset
    full_reset
    
    # Set specific driver parameters
    if [ -f "/sys/module/e1000e/parameters/InterruptThrottleRate" ]; then
        echo "3" > /sys/module/e1000e/parameters/InterruptThrottleRate
    fi
    
    # Configure interface
    ip link set $INTERFACE down
    sleep 2
    ip link set $INTERFACE up
    
    # Restart NetworkManager
    systemctl start NetworkManager
    
    # Wait for link
    for i in $(seq 1 5); do
        if check_link_status; then
            echo "Link detected successfully"
            return 0
        fi
        sleep 1
    done
    
    echo "Failed to detect link after recovery"
    return 1
}

# Main execution
echo "Starting enhanced network recovery"
for attempt in $(seq 1 $MAX_ATTEMPTS); do
    echo "Recovery attempt $attempt of $MAX_ATTEMPTS"
    
    if recover_network; then
        echo "Network recovery successful on attempt $attempt"
        exit 0
    fi
    
    sleep $SLEEP_BETWEEN_ATTEMPTS
done

echo "All recovery attempts failed"
exit 1
