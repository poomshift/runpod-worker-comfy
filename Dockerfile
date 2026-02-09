# Build argument for base image selection
ARG BASE_IMAGE=nvidia/cuda:12.8.0-base-ubuntu24.04

# Stage 1: Base image with common dependencies
FROM ${BASE_IMAGE} AS base

# Build arguments for this stage with sensible defaults for standalone builds
ARG COMFYUI_VERSION=latest
ARG CUDA_VERSION_FOR_COMFY
ARG ENABLE_PYTORCH_UPGRADE=true
ARG PYTORCH_INDEX_URL=https://download.pytorch.org/whl/cu128

# Prevents prompts from packages asking for user input during installation
ENV DEBIAN_FRONTEND=noninteractive
# Prefer binary wheels over source distributions for faster pip installations
ENV PIP_PREFER_BINARY=1
# Ensures output from python is printed immediately to the terminal without buffering
ENV PYTHONUNBUFFERED=1
# Speed up some cmake builds
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Install Python, git and other necessary tools
RUN apt-get update && apt-get install -y \
    python3.12 \
    python3.12-venv \
    python3.12-dev \
    git \
    wget \
    aria2 \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender1 \
    ffmpeg \
    libavcodec-dev \
    libavformat-dev \
    libavutil-dev \
    libswscale-dev \
    libswresample-dev \
    libavfilter-dev \
    libavdevice-dev \
    pkg-config \
    build-essential \
    cmake \
    ninja-build \
    && ln -sf /usr/bin/python3.12 /usr/bin/python \
    && ln -sf /usr/bin/pip3 /usr/bin/pip

# Clean up to reduce image size
RUN apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Install uv (latest) using official installer and create isolated venv
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv /opt/venv

# Use the virtual environment for all subsequent commands
ENV PATH="/opt/venv/bin:${PATH}"

# Install comfy-cli + dependencies needed by it to install ComfyUI
RUN uv pip install comfy-cli pip setuptools wheel

# Install ComfyUI
RUN if [ -n "${CUDA_VERSION_FOR_COMFY}" ]; then \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --cuda-version "${CUDA_VERSION_FOR_COMFY}" --nvidia; \
    else \
      /usr/bin/yes | comfy --workspace /comfyui install --version "${COMFYUI_VERSION}" --nvidia; \
    fi

# Upgrade PyTorch if needed (for newer CUDA versions)
RUN if [ "$ENABLE_PYTORCH_UPGRADE" = "true" ]; then \
      uv pip install --force-reinstall torch==2.9.1 torchvision==0.24.1 torchaudio==2.9.1 --index-url ${PYTORCH_INDEX_URL}; \
    fi

# Verify FFmpeg installation and libraries
RUN ffmpeg -version && ldconfig

# Ensure FFmpeg libraries are in the library cache
RUN echo "/usr/lib/x86_64-linux-gnu" > /etc/ld.so.conf.d/ffmpeg.conf && ldconfig

# Set library path for runtime to ensure FFmpeg libraries are found
ENV LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH}

# Install torchcodec - use pre-built wheel first
RUN uv pip uninstall torchcodec || true && \
    uv pip install --no-cache-dir torchcodec

# Debug: Check what's installed and what libraries are available
RUN echo "=== Checking FFmpeg version ===" && ffmpeg -version | head -5 && \
    echo "=== FFmpeg libraries available ===" && ldconfig -p | grep libav | head -20 && \
    echo "=== Torchcodec .so files ===" && ls -la /opt/venv/lib/python3.12/site-packages/torchcodec/*.so 2>/dev/null || echo "No .so files found" && \
    echo "=== Checking first .so dependencies ===" && \
    for so_file in /opt/venv/lib/python3.12/site-packages/torchcodec/libtorchcodec_core*.so; do \
        if [ -f "$so_file" ]; then \
            echo "Checking $so_file:"; \
            ldd "$so_file" 2>&1 | grep -E "(not found|libav)" || echo "No missing libav libraries"; \
            break; \
        fi; \
    done

# Verify torchcodec installation
RUN python -c "import torchcodec; print('torchcodec version:', torchcodec.__version__); print('torchcodec imported successfully')" || \
    echo "WARNING: torchcodec import failed - will rely on alternative audio loading methods"

# Install sageattention
RUN uv pip install https://huggingface.co/Kijai/PrecompiledWheels/resolve/main/sageattention-2.2.0-cp312-cp312-linux_x86_64.whl
RUN uv pip install https://huggingface.co/vjump21848/sageattention-pre-compiled-wheel/resolve/main/sageattn3-1.0.0%2Bcu128-cp312-cp312-linux_x86_64.whl?download=true

# Change working directory to ComfyUI
WORKDIR /comfyui

# Support for the network volume
ADD src/extra_model_paths.yaml ./

# Go back to the root
WORKDIR /

# Install Python runtime dependencies for the handler
RUN uv pip install runpod requests websocket-client

# Add application code and scripts
ADD src/start.sh handler.py test_input.json ./
RUN chmod +x /start.sh

# Add script to install custom nodes
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install

# install custom nodes using comfy-cli
RUN comfy-node-install comfyui-kjnodes comfyui-videohelpersuite ComfyUI-WanVideoWrapper media-url-loader ComfyUI-MelBandRoFormer RES4LYF ComfyUI-SCAIL-Pose

# Prevent pip from asking for confirmation during uninstall steps in custom nodes
ENV PIP_NO_INPUT=1

# Copy helper script to switch Manager network mode at container start
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode

# Set the default command to run when starting the container
CMD ["/start.sh"]

# Stage 2: Download models
FROM base AS downloader

ARG HUGGINGFACE_ACCESS_TOKEN
# Set default model type if none is provided
ARG MODEL_TYPE=none

# Change working directory to ComfyUI
WORKDIR /comfyui

# Create necessary directories upfront
RUN mkdir -p models/checkpoints models/vae models/unet models/clip models/diffusion_models models/text_encoders models/loras

# Stage 3: Final image
FROM base AS final

# Copy models from stage 2 to the final image
COPY --from=downloader /comfyui/models /comfyui/models
