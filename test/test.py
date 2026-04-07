# SPDX-FileCopyrightText: © 2024 Your Name
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

@cocotb.test()
async def test_vga_lorenz(dut):
    dut._log.info("Starting VGA Lorenz Attractor Test")

    # 1. Set the clock period to 40 ns (25 MHz) for standard 640x480 VGA
    clock = Clock(dut.clk, 40, unit="ns")
    cocotb.start_soon(clock.start())

    # 2. Initialize inputs
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0

    # 3. Apply Reset
    dut._log.info("Resetting DUT")
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    dut._log.info("Reset complete")

    # Wait one cycle for values to propagate
    await ClockCycles(dut.clk, 1)

    # 4. Check static assignments
    assert dut.uio_out.value == 0, "uio_out should be tied to 0"
    assert dut.uio_oe.value == 0, "uio_oe should be tied to 0"

    # Helper function to read the HSYNC bit (uo_out[7])
    def get_hsync():
        return (dut.uo_out.value.integer >> 7) & 1

    # Helper function to read the VSYNC bit (uo_out[3])
    def get_vsync():
        return (dut.uo_out.value.integer >> 3) & 1

    # 5. Test VGA Timing
    dut._log.info("Testing HSYNC timing...")

    # At the start of the line (hpos = 0), HSYNC should be HIGH (active low sync)
    assert get_hsync() == 1, "HSYNC should be high during active video"

    # According to your Verilog: hsync is LOW when hpos >= 656 && hpos < 752
    # Let's advance time to cycle 660 (safely inside the sync pulse)
    await ClockCycles(dut.clk, 660)
    
    assert get_hsync() == 0, "HSYNC should be LOW during the sync pulse (hpos >= 656)"

    # Advance time to cycle 760 (safely out of the sync pulse, hpos > 752)
    await ClockCycles(dut.clk, 100)
    
    assert get_hsync() == 1, "HSYNC should be HIGH again after the sync pulse"

    dut._log.info("HSYNC timing verified successfully!")

    # 6. Run the chaos engine for a bit to ensure it doesn't crash the simulation
    dut._log.info("Running chaos engine logic for a few lines...")
    await ClockCycles(dut.clk, 3000)

    dut._log.info("Simulation passed!")
