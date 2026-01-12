# Neural Network Accelerator RTL Design & FPGA Deployment

This repository contains the handcrafted **SystemVerilog (RTL) FPGA accelerator** developed for the research paper:

**FPGA Implementation of Radar-Based Hand Gesture Recognition: HDL and HLS**  
Rishit Mane, Himanshu Khatri, Prof. Rituparna Choudhury  
International Institute of Information Technology Bangalore (IIIT-B)

---

## 🧠 Project Overview

This project implements a **hardware-aware depthwise-separable convolutional neural network (CNN)** for **radar-based hand gesture recognition** on FPGA.

The associated paper evaluates **two FPGA design methodologies**:

- **Handwritten RTL using SystemVerilog (HDL)**
- **High-Level Synthesis (HLS) using Xilinx Vitis AI (DPU)**

This GitHub repository contains the **complete handcrafted RTL (HDL) implementation** of the accelerator.  
The **HLS/DPU flow is described in the paper** but is not included here because it relies on vendor-generated binaries and runtime frameworks.

---

## 📐 Network & Hardware Architecture

### CNN Architecture
*(From Fig. 1 of the paper)*  
![CNN Architecture](docs/fig1_network.png)

### Handcrafted RTL Accelerator (HDL)
*(From Fig. 2 of the paper)*  
![HDL Architecture](docs/fig2_hdl_arch.png)

### HLS / DPU Accelerator (for comparison)
*(From Fig. 3 of the paper)*  
![HLS Architecture](docs/fig3_hls_arch.png)

---

## 🧩 CNN Execution Pipeline

The handcrafted RTL accelerator implements the following **layer-by-layer execution flow**, exactly matching the paper’s architecture:

DW1 → PW1 → BN → ReLU + Pool
DW2 → PW2 → BN → ReLU + Pool
DW3 → PW3 → BN → ReLU + Pool
GroupConv → FC1 → FC2 (Softmax)


Each block is implemented as an independent SystemVerilog module with dedicated on-chip BRAM buffering.  
A centralized **finite-state machine (FSM)** in `top.sv` controls the execution using `start` and `done` handshakes, enabling deterministic timing and low-power operation.

---

## 🏗️ RTL Accelerator Design

The RTL design follows a **modular, layer-wise hardware architecture**:

- Depthwise and pointwise convolutions for efficient feature extraction  
- Batch normalization, ReLU, and max-pooling for activation and downsampling  
- Grouped convolution for reduced computation and improved channel mixing  
- Two fully connected layers for classification  

All intermediate feature maps, weights, and biases are stored in **on-chip BRAMs** to minimize external memory access and improve power efficiency.

---

```text
📁 Neural-Network-Accelerator-RTL-FPGA
│
├── 📁 src
│   ├── 📁 depthwise_conv        # Depthwise convolution layers
│   ├── 📁 pointwise_conv        # 1×1 pointwise convolutions
│   ├── 📁 batch_norm            # Batch normalization
│   ├── 📁 ReLU_Pool             # ReLU activation + Max Pooling
│   ├── 📁 grouped_conv          # Grouped convolution
│   ├── 📁 fc_layer              # Fully connected layers
│   └── 📄 top.sv                # Top-level module with FSM and BRAM controller
│
├── 📁 constraints
│   └── 📄 constraints_top.xdc   # FPGA pin & timing constraints
│
├── 📁 docs
│   ├── 📄 FPGA_Implementation_of_Radar_Based_Hand_Gesture_Recognition_HDL_and_HLS.pdf
│   ├── 🖼️ fig1_network.png      # CNN architecture
│   ├── 🖼️ fig2_hdl_arch.png     # HDL accelerator architecture
│   └── 🖼️ fig3_hls_arch.png     # HLS (Vitis AI DPU) architecture
│
└── 📄 README.md


```

---

## 🖥️ Target Platform

- **FPGA Board:** Xilinx ZCU104 (Zynq UltraScale+ MPSoC)  
- **Clock Frequency (HDL):** 95 MHz  
- **Tools:** Xilinx Vivado 2023.1  

---

## 📊 Performance Summary (from Paper)

| Metric | HDL (RTL) | HLS (Vitis AI) |
|------|----------|----------------|
| Frequency | 95 MHz | 300 MHz |
| LUTs | ~10.8k | ~51.8k |
| DSPs | 11 | 710 |
| Power | 0.743 W | 3.623 W |
| Accuracy | 80.0% | 81.04% |

---

## 📚 Reference

If you use or build upon this work, please cite:

**FPGA Implementation of Radar-Based Hand Gesture Recognition: HDL and HLS**  
Rishit Mane, Himanshu Khatri, Prof. Rituparna Choudhury  
International Institute of Information Technology Bangalore (IIIT-B)

The full paper is included in the `docs/` directory.

---
