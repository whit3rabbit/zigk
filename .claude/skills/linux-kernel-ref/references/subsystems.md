# Linux Kernel Subsystem Quick Reference

Quick reference for common subsystem patterns used when implementing drivers.

## PCI Driver Pattern

```c
// Driver structure
static struct pci_driver my_driver = {
    .name = "my_driver",
    .id_table = my_pci_ids,
    .probe = my_probe,
    .remove = my_remove,
};

// Device ID table
static const struct pci_device_id my_pci_ids[] = {
    { PCI_DEVICE(0x8086, 0x1234) },  // vendor, device
    { 0, }  // terminator
};

// Probe function
static int my_probe(struct pci_dev *pdev, const struct pci_device_id *id)
{
    int err;

    // Enable device
    err = pci_enable_device(pdev);
    if (err)
        return err;

    // Request regions (BARs)
    err = pci_request_regions(pdev, "my_driver");
    if (err)
        goto err_disable;

    // Enable bus mastering for DMA
    pci_set_master(pdev);

    // Map BAR0
    void __iomem *regs = pci_iomap(pdev, 0, 0);
    if (!regs) {
        err = -ENOMEM;
        goto err_release;
    }

    // ... driver init ...

    return 0;

err_release:
    pci_release_regions(pdev);
err_disable:
    pci_disable_device(pdev);
    return err;
}
```

## MMIO Access Pattern

```c
// Read/write 32-bit registers
u32 val = readl(regs + OFFSET);
writel(val, regs + OFFSET);

// Alternative (same thing)
u32 val = ioread32(regs + OFFSET);
iowrite32(val, regs + OFFSET);

// Memory barriers
wmb();  // Write barrier
rmb();  // Read barrier
mb();   // Full barrier

// Register polling
static int poll_reg(void __iomem *regs, u32 mask, u32 expected, int timeout_us)
{
    u32 val;
    return readl_poll_timeout(regs + REG_STATUS, val,
                              (val & mask) == expected,
                              10, timeout_us);
}
```

## MSI-X Interrupt Pattern

```c
// Allocate MSI-X vectors
int nvec = pci_alloc_irq_vectors(pdev, 1, max_vectors, PCI_IRQ_MSIX | PCI_IRQ_MSI);
if (nvec < 0)
    return nvec;

// Get vector number
int vector = pci_irq_vector(pdev, 0);

// Request IRQ
err = request_irq(vector, my_irq_handler, 0, "my_driver", priv);

// IRQ handler
static irqreturn_t my_irq_handler(int irq, void *data)
{
    struct my_priv *priv = data;

    // Read and clear interrupt status
    u32 status = readl(priv->regs + REG_INT_STATUS);
    if (!status)
        return IRQ_NONE;

    writel(status, priv->regs + REG_INT_STATUS);  // Clear

    // Handle interrupt
    // ...

    return IRQ_HANDLED;
}

// Cleanup
free_irq(vector, priv);
pci_free_irq_vectors(pdev);
```

## DMA Buffer Allocation

```c
// Coherent DMA buffer (always consistent)
void *buf = dma_alloc_coherent(&pdev->dev, size, &dma_addr, GFP_KERNEL);
// buf = CPU address, dma_addr = device address

// Single-use mapping
dma_addr_t dma = dma_map_single(&pdev->dev, buf, size, DMA_TO_DEVICE);
// DMA_TO_DEVICE, DMA_FROM_DEVICE, DMA_BIDIRECTIONAL

// Set DMA mask
err = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
if (err)
    err = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));

// Cleanup
dma_unmap_single(&pdev->dev, dma, size, DMA_TO_DEVICE);
dma_free_coherent(&pdev->dev, size, buf, dma_addr);
```

## DRM/KMS Driver Pattern

```c
// Driver structure
static const struct drm_driver my_drm_driver = {
    .driver_features = DRIVER_GEM | DRIVER_MODESET | DRIVER_ATOMIC,
    .name = "my_gpu",
    .desc = "My GPU Driver",
    .date = "20240101",
    .fops = &my_fops,
};

// CRTC functions
static const struct drm_crtc_funcs my_crtc_funcs = {
    .set_config = drm_atomic_helper_set_config,
    .page_flip = drm_atomic_helper_page_flip,
    .destroy = drm_crtc_cleanup,
    .reset = drm_atomic_helper_crtc_reset,
    .atomic_duplicate_state = drm_atomic_helper_crtc_duplicate_state,
    .atomic_destroy_state = drm_atomic_helper_crtc_destroy_state,
};

// Mode setting
static const struct drm_mode_config_funcs my_mode_config_funcs = {
    .fb_create = drm_gem_fb_create,
    .atomic_check = drm_atomic_helper_check,
    .atomic_commit = drm_atomic_helper_commit,
};
```

## Network Driver Pattern

```c
// Net device operations
static const struct net_device_ops my_netdev_ops = {
    .ndo_open = my_open,
    .ndo_stop = my_stop,
    .ndo_start_xmit = my_xmit,
    .ndo_set_rx_mode = my_set_rx_mode,
    .ndo_get_stats64 = my_get_stats,
};

// NAPI polling
static int my_poll(struct napi_struct *napi, int budget)
{
    struct my_priv *priv = container_of(napi, struct my_priv, napi);
    int work_done = 0;

    // Process RX packets
    while (work_done < budget) {
        // ... process packet ...
        work_done++;
    }

    if (work_done < budget) {
        napi_complete_done(napi, work_done);
        // Re-enable interrupts
        writel(INT_RX, priv->regs + REG_INT_ENABLE);
    }

    return work_done;
}

// Transmit
static netdev_tx_t my_xmit(struct sk_buff *skb, struct net_device *dev)
{
    struct my_priv *priv = netdev_priv(dev);

    // Map buffer for DMA
    dma_addr_t dma = dma_map_single(&priv->pdev->dev,
                                     skb->data, skb->len,
                                     DMA_TO_DEVICE);

    // Set up TX descriptor
    // ...

    return NETDEV_TX_OK;
}
```

## Block Driver Pattern (blk-mq)

```c
// Queue operations
static const struct blk_mq_ops my_mq_ops = {
    .queue_rq = my_queue_rq,
    .complete = my_complete,
};

// Queue request handler
static blk_status_t my_queue_rq(struct blk_mq_hw_ctx *hctx,
                                 const struct blk_mq_queue_data *bd)
{
    struct request *rq = bd->rq;
    struct my_priv *priv = hctx->driver_data;

    blk_mq_start_request(rq);

    // Process request
    // ...

    return BLK_STS_OK;
}
```

## USB Driver Pattern

```c
// USB driver structure
static struct usb_driver my_usb_driver = {
    .name = "my_usb",
    .id_table = my_usb_ids,
    .probe = my_probe,
    .disconnect = my_disconnect,
};

// Device ID table
static const struct usb_device_id my_usb_ids[] = {
    { USB_DEVICE(0x1234, 0x5678) },
    { }
};

// Probe
static int my_probe(struct usb_interface *intf,
                    const struct usb_device_id *id)
{
    struct usb_device *udev = interface_to_usbdev(intf);
    struct usb_endpoint_descriptor *ep;

    // Find endpoints
    ep = &intf->cur_altsetting->endpoint[0].desc;

    // Allocate URB
    struct urb *urb = usb_alloc_urb(0, GFP_KERNEL);

    // Submit URB
    usb_fill_bulk_urb(urb, udev, pipe, buf, len, callback, context);
    usb_submit_urb(urb, GFP_KERNEL);

    return 0;
}
```

## Common Macros

```c
// Container access
struct my_priv *priv = container_of(ptr, struct my_priv, member);

// Device private data
struct my_priv *priv = pci_get_drvdata(pdev);
pci_set_drvdata(pdev, priv);

// Error handling
err = PTR_ERR(ptr);
if (IS_ERR(ptr))
    return PTR_ERR(ptr);

// Bit manipulation
#define REG_CTRL_ENABLE   BIT(0)
#define REG_CTRL_RESET    BIT(1)
#define REG_STATUS_BUSY   BIT(31)

val |= REG_CTRL_ENABLE;   // Set bit
val &= ~REG_CTRL_RESET;   // Clear bit
if (val & REG_STATUS_BUSY) // Test bit
```
